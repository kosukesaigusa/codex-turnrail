use crate::account_routing::AccountRouting;
use crate::account_routing::AccountRoutingError;
use codex_backend_client::Client as BackendClient;
use codex_config::types::AuthCredentialsStoreMode;
use codex_core::config::Config;
use codex_login::AuthManager;
use codex_login::CodexAuth;
use codex_protocol::ThreadId;
use codex_protocol::protocol::RateLimitSnapshot;
use codex_utils_absolute_path::AbsolutePathBuf;
use serde::Deserialize;
use serde::Serialize;
use std::collections::HashMap;
use std::collections::HashSet;
use std::fmt;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::Mutex;
use uuid::Uuid;

const TURNRAIL_ROOT_ENV_VAR: &str = "CODEX_TURNRAIL_ROOT";
const STATE_FILE_NAME: &str = "state.json";
const SUPPORTED_SCHEMA_VERSION: u64 = 3;

#[derive(Clone, Debug)]
pub(crate) struct TurnrailCoordinator {
    root: PathBuf,
    owner_by_thread_id: Arc<Mutex<HashMap<ThreadId, Uuid>>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct SelectedAccount {
    pub(crate) id: Uuid,
    pub(crate) email: String,
    pub(crate) plan_type: RegistryPlanType,
    pub(crate) auth_home: PathBuf,
}

#[derive(Clone)]
pub(crate) struct SelectedAuthentication {
    pub(crate) account_id: Uuid,
    pub(crate) auth_manager: Arc<AuthManager>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct UnavailableAccount {
    email: String,
    plan_type: RegistryPlanType,
    reason: AccountUnavailableReason,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum AccountUnavailableReason {
    LoginRequired,
    AuthenticationRefreshFailed,
    CodexQuotaExhausted,
}

impl fmt::Display for AccountUnavailableReason {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::LoginRequired => formatter.write_str("login required"),
            Self::AuthenticationRefreshFailed => {
                formatter.write_str("authentication refresh failed")
            }
            Self::CodexQuotaExhausted => formatter.write_str("Codex quota exhausted"),
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum TurnrailError {
    #[error("{TURNRAIL_ROOT_ENV_VAR} must be an absolute path: {0}")]
    RelativeRoot(PathBuf),
    #[error("failed to read Turnrail state at {path}: {source}")]
    ReadState {
        path: PathBuf,
        source: std::io::Error,
    },
    #[error("failed to parse Turnrail state at {path}: {source}")]
    ParseState {
        path: PathBuf,
        source: serde_json::Error,
    },
    #[error("Turnrail schema version {0} is not supported")]
    UnsupportedSchemaVersion(u64),
    #[error("Turnrail state does not contain any accounts")]
    NoAccounts,
    #[error(transparent)]
    Routing(#[from] AccountRoutingError),
    #[error("Turnrail account {0} has an invalid email address")]
    InvalidEmail(Uuid),
    #[error("saved authentication for account {0} does not contain an email address")]
    MissingAuthenticationEmail(Uuid),
    #[error(
        "account identity mismatch: registry email {expected_email}, saved authentication email {actual_email}"
    )]
    AuthenticationEmailMismatch {
        expected_email: String,
        actual_email: String,
    },
    #[error("Turnrail state contains duplicate account id {0}")]
    DuplicateAccountId(Uuid),
    #[error("Turnrail state contains duplicate email address {0}")]
    DuplicateEmail(String),
    #[error("failed to create account authentication home at {path}: {source}")]
    CreateAuthHome {
        path: PathBuf,
        source: std::io::Error,
    },
    #[error("account authentication home is not an absolute path: {0}")]
    InvalidAuthHome(PathBuf),
    #[error("failed to initialize authentication for account {account_id}: {source}")]
    InitializeAuth {
        account_id: Uuid,
        source: codex_login::AuthManagerInitializationError,
    },
    #[error("failed to inspect Codex quota for account {account_id}: {source}")]
    InspectRateLimits {
        account_id: Uuid,
        source: anyhow::Error,
    },
    #[error("Codex quota response for account {0} did not contain the general Codex quota")]
    MissingGeneralRateLimits(Uuid),
    #[error("Codex quota response for account {account_id} contained invalid used percent {value}")]
    InvalidRateLimitPercentage { account_id: Uuid, value: f64 },
    #[error("no Codex Turnrail account is available: {0}")]
    NoAvailableAccount(String),
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RegistryState {
    schema_version: u64,
    revision: u64,
    accounts: Vec<RegistryAccount>,
    routing: AccountRouting,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RegistryAccount {
    id: Uuid,
    email: String,
    #[serde(rename = "planType")]
    plan_type: RegistryPlanType,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum RegistryPlanType {
    Free,
    Go,
    Plus,
    Pro,
    #[serde(rename = "prolite")]
    ProLite,
    Team,
    SelfServeBusinessProlite,
    SelfServeBusinessUsageBased,
    Business,
    Ent26,
    EnterpriseCbpAutomation,
    EnterpriseCbpUsageBased,
    Enterprise,
    Edu,
    EduPlus,
    EduPro,
    Unknown,
}

impl fmt::Display for RegistryPlanType {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Free => "Free",
            Self::Go => "Go",
            Self::Plus => "Plus",
            Self::Pro => "Pro",
            Self::ProLite => "Pro Lite",
            Self::Team => "Team",
            Self::SelfServeBusinessProlite => "Business Pro Lite",
            Self::SelfServeBusinessUsageBased => "Business Usage Based",
            Self::Business => "Business",
            Self::Ent26
            | Self::EnterpriseCbpAutomation
            | Self::EnterpriseCbpUsageBased
            | Self::Enterprise => "Enterprise",
            Self::Edu => "Education",
            Self::EduPlus => "Education Plus",
            Self::EduPro => "Education Pro",
            Self::Unknown => "Unknown plan",
        })
    }
}

impl TurnrailCoordinator {
    pub(crate) fn from_process_environment() -> Result<Option<Self>, TurnrailError> {
        let Some(root) = std::env::var_os(TURNRAIL_ROOT_ENV_VAR) else {
            return Ok(None);
        };
        Self::from_root(PathBuf::from(root)).map(Some)
    }

    pub(crate) fn from_root(root: PathBuf) -> Result<Self, TurnrailError> {
        if !root.is_absolute() {
            return Err(TurnrailError::RelativeRoot(root));
        }
        Ok(Self {
            root,
            owner_by_thread_id: Arc::new(Mutex::new(HashMap::new())),
        })
    }

    pub(crate) async fn selected_authentication(
        &self,
        base_config: &Config,
        cwd: &AbsolutePathBuf,
    ) -> Result<SelectedAuthentication, TurnrailError> {
        let accounts = self.ordered_accounts(cwd).await?;
        let mut skipped_accounts = Vec::new();
        for selected in accounts {
            let authentication = self
                .authentication_for_account(selected.clone(), base_config)
                .await?;
            let unavailability = self
                .account_unavailability(
                    &selected,
                    Arc::clone(&authentication.auth_manager),
                    base_config,
                )
                .await?;
            match unavailability {
                Some(reason) => skipped_accounts.push(UnavailableAccount {
                    email: selected.email,
                    plan_type: selected.plan_type,
                    reason,
                }),
                None => {
                    return Ok(authentication);
                }
            }
        }

        let reasons = skipped_accounts
            .iter()
            .map(|account| format!("{} ({})", account.email, account.reason))
            .collect::<Vec<_>>()
            .join(", ");
        Err(TurnrailError::NoAvailableAccount(reasons))
    }

    pub(crate) async fn authentication_for_account(
        &self,
        selected: SelectedAccount,
        base_config: &Config,
    ) -> Result<SelectedAuthentication, TurnrailError> {
        tokio::fs::create_dir_all(&selected.auth_home)
            .await
            .map_err(|source| TurnrailError::CreateAuthHome {
                path: selected.auth_home.clone(),
                source,
            })?;

        let mut account_config = base_config.clone();
        account_config.codex_home = AbsolutePathBuf::from_absolute_path(&selected.auth_home)
            .map_err(|_| TurnrailError::InvalidAuthHome(selected.auth_home.clone()))?;
        account_config.cli_auth_credentials_store_mode = AuthCredentialsStoreMode::Keyring;

        let auth_manager = AuthManager::shared_from_config(
            &account_config,
            /*enable_codex_api_key_env*/ false,
        )
        .await
        .map_err(|source| TurnrailError::InitializeAuth {
            account_id: selected.id,
            source,
        })?;
        Ok(SelectedAuthentication {
            account_id: selected.id,
            auth_manager,
        })
    }

    async fn account_unavailability(
        &self,
        selected: &SelectedAccount,
        auth_manager: Arc<AuthManager>,
        base_config: &Config,
    ) -> Result<Option<AccountUnavailableReason>, TurnrailError> {
        let account_id = selected.id;
        let Some(cached_auth) = auth_manager.auth_cached() else {
            return Ok(Some(AccountUnavailableReason::LoginRequired));
        };
        if !cached_auth.uses_codex_backend() {
            return Ok(Some(AccountUnavailableReason::LoginRequired));
        }
        ensure_authentication_email_matches(selected, &cached_auth)?;

        let Some(auth) = auth_manager.auth().await else {
            return Ok(Some(AccountUnavailableReason::LoginRequired));
        };
        if !auth.uses_codex_backend() {
            return Ok(Some(AccountUnavailableReason::LoginRequired));
        }
        ensure_authentication_email_matches(selected, &auth)?;
        if auth_manager.refresh_failure_for_auth(&auth).is_some() {
            return Ok(Some(AccountUnavailableReason::AuthenticationRefreshFailed));
        }

        let rate_limits = BackendClient::from_auth(
            base_config.chatgpt_base_url.clone(),
            &auth,
            base_config.http_client_factory(),
        )
        .get_rate_limits_many()
        .await
        .map_err(|source| TurnrailError::InspectRateLimits { account_id, source })?;
        let general_rate_limits = rate_limits
            .iter()
            .find(|snapshot| {
                snapshot.limit_id.as_deref() == Some("codex") || snapshot.limit_id.is_none()
            })
            .ok_or(TurnrailError::MissingGeneralRateLimits(account_id))?;
        if general_codex_quota_is_exhausted(account_id, general_rate_limits)? {
            return Ok(Some(AccountUnavailableReason::CodexQuotaExhausted));
        }
        Ok(None)
    }

    pub(crate) async fn owner_matches(&self, thread_id: ThreadId, account_id: Uuid) -> bool {
        self.owner_by_thread_id
            .lock()
            .await
            .get(&thread_id)
            .is_some_and(|owner| *owner == account_id)
    }

    pub(crate) async fn record_owner(&self, thread_id: ThreadId, account_id: Uuid) {
        self.owner_by_thread_id
            .lock()
            .await
            .insert(thread_id, account_id);
    }

    pub(crate) async fn record_turn_started(
        &self,
        thread_id: ThreadId,
        started_at: Option<i64>,
    ) -> anyhow::Result<()> {
        let Some(account_id) = self
            .owner_by_thread_id
            .lock()
            .await
            .get(&thread_id)
            .copied()
        else {
            return Ok(());
        };
        let started_at = started_at
            .ok_or_else(|| anyhow::anyhow!("turn start event is missing its timestamp"))?;
        let root = self.root.clone();
        tokio::task::spawn_blocking(move || {
            crate::account_last_used::record(&root, account_id, started_at)
        })
        .await?
    }

    #[cfg(test)]
    async fn selected_account(&self) -> Result<SelectedAccount, TurnrailError> {
        let cwd = AbsolutePathBuf::from_absolute_path(&self.root).expect("absolute test root");
        let mut accounts = self.ordered_accounts(&cwd).await?;
        Ok(accounts.remove(0))
    }

    pub(crate) async fn assigned_authentications(
        &self,
        config: &Config,
    ) -> anyhow::Result<Vec<SelectedAuthentication>> {
        let state = self.read_registry().await?;
        Self::validate_registry(&state)?;
        let assigned = state.routing.all_assigned_account_ids();
        anyhow::ensure!(!assigned.is_empty(), "No accounts are assigned to folders");
        let mut authentications = Vec::new();
        for account in &state.accounts {
            if !assigned.contains(&account.id) {
                continue;
            }
            let selected = self.selected_account_from_registry(account);
            let authentication = self
                .authentication_for_account(selected.clone(), config)
                .await?;
            let manager = &authentication.auth_manager;
            let cached = manager.auth_cached().ok_or_else(|| {
                anyhow::anyhow!("Sign in to {} to load its models", selected.email)
            })?;
            ensure_authentication_email_matches(&selected, &cached)?;
            let auth = manager.auth().await.ok_or_else(|| {
                anyhow::anyhow!("Sign in to {} to load its models", selected.email)
            })?;
            ensure_authentication_email_matches(&selected, &auth)?;
            anyhow::ensure!(
                auth.uses_codex_backend() && manager.refresh_failure_for_auth(&auth).is_none(),
                "Sign in to {} to load its models",
                selected.email
            );
            authentications.push(authentication);
        }
        Ok(authentications)
    }

    async fn ordered_accounts(
        &self,
        cwd: &AbsolutePathBuf,
    ) -> Result<Vec<SelectedAccount>, TurnrailError> {
        self.validate_and_order(self.read_registry().await?, cwd)
            .await
    }

    async fn read_registry(&self) -> Result<RegistryState, TurnrailError> {
        let state_path = self.root.join(STATE_FILE_NAME);
        let bytes =
            tokio::fs::read(&state_path)
                .await
                .map_err(|source| TurnrailError::ReadState {
                    path: state_path.clone(),
                    source,
                })?;
        let value: serde_json::Value =
            serde_json::from_slice(&bytes).map_err(|source| TurnrailError::ParseState {
                path: state_path.clone(),
                source,
            })?;
        let state: RegistryState =
            serde_json::from_value(value).map_err(|source| TurnrailError::ParseState {
                path: state_path,
                source,
            })?;
        Ok(state)
    }

    async fn validate_and_order(
        &self,
        state: RegistryState,
        cwd: &AbsolutePathBuf,
    ) -> Result<Vec<SelectedAccount>, TurnrailError> {
        Self::validate_registry(&state)?;
        let ordered_ids = state.routing.ordered_account_ids(cwd).await?;
        let accounts = ordered_ids
            .iter()
            .map(|id| {
                let account = state
                    .accounts
                    .iter()
                    .find(|account| account.id == *id)
                    .ok_or(AccountRoutingError::UnknownAccount(*id))?;
                Ok(self.selected_account_from_registry(account))
            })
            .collect::<Result<Vec<_>, TurnrailError>>()?;
        Ok(accounts)
    }

    fn validate_registry(state: &RegistryState) -> Result<(), TurnrailError> {
        if state.schema_version != SUPPORTED_SCHEMA_VERSION {
            return Err(TurnrailError::UnsupportedSchemaVersion(
                state.schema_version,
            ));
        }
        let _revision = state.revision;
        if state.accounts.is_empty() {
            return Err(TurnrailError::NoAccounts);
        }

        let mut account_ids = HashSet::new();
        let mut account_emails = HashSet::new();
        for account in &state.accounts {
            let email = account.email.trim().to_lowercase();
            if !is_valid_email(&email) || account.email != email {
                return Err(TurnrailError::InvalidEmail(account.id));
            }
            if !account_ids.insert(account.id) {
                return Err(TurnrailError::DuplicateAccountId(account.id));
            }
            if !account_emails.insert(email.clone()) {
                return Err(TurnrailError::DuplicateEmail(email));
            }
        }

        state.routing.validate(&account_ids)?;
        Ok(())
    }

    fn selected_account_from_registry(&self, account: &RegistryAccount) -> SelectedAccount {
        SelectedAccount {
            id: account.id,
            email: account.email.clone(),
            plan_type: account.plan_type.clone(),
            auth_home: self
                .root
                .join("accounts")
                .join(account.id.to_string())
                .join("auth-home"),
        }
    }
}

fn general_codex_quota_is_exhausted(
    account_id: Uuid,
    snapshot: &RateLimitSnapshot,
) -> Result<bool, TurnrailError> {
    for window in [snapshot.primary.as_ref(), snapshot.secondary.as_ref()]
        .into_iter()
        .flatten()
    {
        if !window.used_percent.is_finite() || !(0.0..=100.0).contains(&window.used_percent) {
            return Err(TurnrailError::InvalidRateLimitPercentage {
                account_id,
                value: window.used_percent,
            });
        }
    }
    Ok(snapshot.rate_limit_reached_type.is_some()
        || snapshot.spend_control_reached == Some(true)
        || [snapshot.primary.as_ref(), snapshot.secondary.as_ref()]
            .into_iter()
            .flatten()
            .any(|window| window.used_percent == 100.0))
}

fn ensure_authentication_email_matches(
    selected: &SelectedAccount,
    auth: &CodexAuth,
) -> Result<(), TurnrailError> {
    let actual_email = auth
        .get_account_email()
        .filter(|email| !email.trim().is_empty())
        .ok_or(TurnrailError::MissingAuthenticationEmail(selected.id))?;
    if actual_email.trim().to_lowercase() != selected.email.trim().to_lowercase() {
        return Err(TurnrailError::AuthenticationEmailMismatch {
            expected_email: selected.email.clone(),
            actual_email,
        });
    }
    Ok(())
}

fn is_valid_email(email: &str) -> bool {
    let Some((local, domain)) = email.split_once('@') else {
        return false;
    };
    !local.is_empty() && !domain.is_empty() && !domain.contains('@')
}

#[cfg(test)]
mod tests {
    use super::*;
    use codex_protocol::protocol::RateLimitWindow;
    use pretty_assertions::assert_eq;
    use serde_json::json;
    use std::path::Path;

    const ACCOUNT_ID: &str = "11111111-1111-4111-8111-111111111111";

    fn write_state(root: &Path, state: serde_json::Value) {
        std::fs::write(
            root.join(STATE_FILE_NAME),
            serde_json::to_vec_pretty(&state).expect("serialize state"),
        )
        .expect("write state");
    }

    #[tokio::test]
    async fn loads_the_selected_account_and_derives_its_auth_home() {
        let root = tempfile::tempdir().expect("tempdir");
        write_state(
            root.path(),
            json!({
                "schemaVersion": 3,
                "revision": 2,
                "routing": {"defaultAccountIDs": [ACCOUNT_ID], "directoryRules": []},
                "accounts": [{
                    "id": ACCOUNT_ID,
                    "email": "primary@example.com",
                    "planType": "pro"
                }]
            }),
        );
        let coordinator =
            TurnrailCoordinator::from_root(root.path().to_path_buf()).expect("coordinator");

        let selected = coordinator
            .selected_account()
            .await
            .expect("selected account");

        assert_eq!(
            selected,
            SelectedAccount {
                id: Uuid::parse_str(ACCOUNT_ID).expect("account id"),
                email: "primary@example.com".to_string(),
                plan_type: RegistryPlanType::Pro,
                auth_home: root
                    .path()
                    .join("accounts")
                    .join(ACCOUNT_ID)
                    .join("auth-home"),
            }
        );
    }

    #[tokio::test]
    async fn orders_only_accounts_permitted_by_the_rule() {
        let root = tempfile::tempdir().expect("tempdir");
        let first_id = ACCOUNT_ID;
        let second_id = "22222222-2222-4222-8222-222222222222";
        let selected_id = "33333333-3333-4333-8333-333333333333";
        write_state(
            root.path(),
            json!({
                "schemaVersion": 3,
                "revision": 1,
                "routing": {"defaultAccountIDs": [selected_id, first_id], "directoryRules": []},
                "accounts": [
                    {"id": first_id, "email": "first@example.com", "planType": "pro"},
                    {"id": second_id, "email": "second@example.com", "planType": "plus"},
                    {"id": selected_id, "email": "selected@example.com", "planType": "pro"}
                ]
            }),
        );
        let coordinator =
            TurnrailCoordinator::from_root(root.path().to_path_buf()).expect("coordinator");

        let cwd = AbsolutePathBuf::from_absolute_path(root.path()).expect("cwd");
        let accounts = coordinator
            .ordered_accounts(&cwd)
            .await
            .expect("account order");

        assert_eq!(
            accounts
                .iter()
                .map(|account| account.email.as_str())
                .collect::<Vec<_>>(),
            vec!["selected@example.com", "first@example.com"]
        );
    }

    #[test]
    fn detects_exhausted_general_codex_quota() {
        let account_id = Uuid::parse_str(ACCOUNT_ID).expect("account id");
        let snapshot = RateLimitSnapshot {
            limit_id: Some("codex".to_string()),
            limit_name: None,
            primary: Some(RateLimitWindow {
                used_percent: 100.0,
                window_minutes: Some(10_080),
                resets_at: Some(1_700_000_000),
            }),
            secondary: None,
            credits: None,
            individual_limit: None,
            spend_control_reached: None,
            plan_type: None,
            rate_limit_reached_type: None,
        };

        assert!(
            general_codex_quota_is_exhausted(account_id, &snapshot)
                .expect("valid rate limit snapshot")
        );
    }

    #[tokio::test]
    async fn reloads_state_for_each_selection_snapshot() {
        let root = tempfile::tempdir().expect("tempdir");
        let first_id = ACCOUNT_ID;
        let second_id = "22222222-2222-4222-8222-222222222222";
        let state = |selected_account_id: &str| {
            json!({
                "schemaVersion": 3,
                "revision": 1,
                "routing": {"defaultAccountIDs": [selected_account_id], "directoryRules": []},
                "accounts": [
                    {"id": first_id, "email": "primary@example.com", "planType": "pro"},
                    {"id": second_id, "email": "secondary@example.com", "planType": "plus"}
                ]
            })
        };
        write_state(root.path(), state(first_id));
        let coordinator =
            TurnrailCoordinator::from_root(root.path().to_path_buf()).expect("coordinator");

        assert_eq!(
            coordinator
                .selected_account()
                .await
                .expect("first selection")
                .id
                .to_string(),
            first_id
        );
        write_state(root.path(), state(second_id));
        assert_eq!(
            coordinator
                .selected_account()
                .await
                .expect("second selection")
                .id
                .to_string(),
            second_id
        );
    }

    #[tokio::test]
    async fn rejects_missing_routing_configuration() {
        let root = tempfile::tempdir().expect("tempdir");
        write_state(
            root.path(),
            json!({"schemaVersion": 3, "revision": 0, "accounts": []}),
        );
        let coordinator =
            TurnrailCoordinator::from_root(root.path().to_path_buf()).expect("coordinator");

        let error = coordinator
            .selected_account()
            .await
            .expect_err("missing routing configuration must fail");

        assert!(matches!(error, TurnrailError::ParseState { .. }));
    }

    #[tokio::test]
    async fn rejects_duplicate_account_emails() {
        let root = tempfile::tempdir().expect("tempdir");
        write_state(
            root.path(),
            json!({
                "schemaVersion": 3,
                "revision": 1,
                "routing": {"defaultAccountIDs": [ACCOUNT_ID], "directoryRules": []},
                "accounts": [
                    {"id": ACCOUNT_ID, "email": "same@example.com", "planType": "pro"},
                    {
                        "id": "22222222-2222-4222-8222-222222222222",
                        "email": "same@example.com",
                        "planType": "plus"
                    }
                ]
            }),
        );
        let coordinator =
            TurnrailCoordinator::from_root(root.path().to_path_buf()).expect("coordinator");

        let error = coordinator
            .selected_account()
            .await
            .expect_err("duplicate email must fail");

        assert!(matches!(error, TurnrailError::DuplicateEmail(_)));
    }

    #[tokio::test]
    async fn records_the_account_that_owns_a_loaded_thread() {
        let root = tempfile::tempdir().expect("tempdir");
        let coordinator =
            TurnrailCoordinator::from_root(root.path().to_path_buf()).expect("coordinator");
        let thread_id =
            ThreadId::from_string("33333333-3333-4333-8333-333333333333").expect("thread id");
        let first_account_id = Uuid::parse_str(ACCOUNT_ID).expect("account id");
        let second_account_id =
            Uuid::parse_str("22222222-2222-4222-8222-222222222222").expect("account id");

        assert!(!coordinator.owner_matches(thread_id, first_account_id).await);
        coordinator.record_owner(thread_id, first_account_id).await;
        assert!(coordinator.owner_matches(thread_id, first_account_id).await);
        assert!(
            !coordinator
                .owner_matches(thread_id, second_account_id)
                .await
        );
    }
}
