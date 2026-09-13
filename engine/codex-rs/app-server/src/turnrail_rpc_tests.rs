use crate::turnrail::TurnrailCoordinator;

#[path = "account_last_used_rpc_tests.rs"]
mod last_used_tests;
#[path = "account_routing_rpc_tests.rs"]
mod routing_tests;
use crate::config_manager::ConfigManager;
use crate::message_processor::ConnectionSessionState;
use crate::message_processor::MessageProcessor;
use crate::message_processor::MessageProcessorArgs;
use crate::outgoing_message::ConnectionId;
use crate::outgoing_message::OutgoingEnvelope;
use crate::outgoing_message::OutgoingMessage;
use crate::outgoing_message::OutgoingMessageSender;
use crate::transport::AppServerTransport;
use anyhow::Context;
use anyhow::Result;
use app_test_support::ChatGptAuthFixture;
use app_test_support::MockResponsesConfig;
use app_test_support::write_chatgpt_auth;
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use codex_analytics::AnalyticsEventsClient;
use codex_analytics::AppServerRpcTransport;
use codex_app_server_protocol::InitializeResponse;
use codex_app_server_protocol::JSONRPCRequest;
use codex_app_server_protocol::RequestId;
use codex_app_server_protocol::ServerNotification;
use codex_app_server_protocol::ThreadForkResponse;
use codex_app_server_protocol::ThreadListResponse;
use codex_app_server_protocol::ThreadLoadedListResponse;
use codex_app_server_protocol::ThreadReadResponse;
use codex_app_server_protocol::ThreadRevertResponse;
use codex_app_server_protocol::ThreadStartResponse;
use codex_app_server_protocol::TurnCompletedNotification;
use codex_app_server_protocol::TurnStartResponse;
use codex_app_server_protocol::TurnStatus;
use codex_arg0::Arg0DispatchPaths;
use codex_config::CloudConfigBundleLoader;
use codex_config::LoaderOverrides;
use codex_config::types::AuthCredentialsStoreMode;
use codex_core::config::ConfigBuilder;
use codex_exec_server::EnvironmentManager;
use codex_features::Feature;
use codex_feedback::CodexFeedback;
use codex_login::AuthDotJson;
use codex_login::AuthKeyringBackendKind;
use codex_login::AuthManager;
use codex_login::REFRESH_TOKEN_URL_OVERRIDE_ENV_VAR;
use codex_login::save_auth;
use codex_protocol::protocol::SessionSource;
use core_test_support::responses;
use core_test_support::responses::ResponsesRequest;
use keyring::credential::Credential;
use keyring::credential::CredentialApi;
use keyring::credential::CredentialBuilderApi;
use keyring::credential::CredentialPersistence;
use keyring::mock::MockCredential;
use pretty_assertions::assert_eq;
use serde::de::DeserializeOwned;
use serde_json::Value;
use serde_json::json;
use std::any::Any;
use std::collections::HashMap;
use std::collections::VecDeque;
use std::future::Future;
use std::path::Path;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::Once;
use std::time::Duration;
use tempfile::TempDir;
use tokio::sync::mpsc;
use wiremock::Mock;
use wiremock::MockServer;
use wiremock::ResponseTemplate;
use wiremock::matchers::header;
use wiremock::matchers::method;
use wiremock::matchers::path;

const ACCOUNT_A: &str = "11111111-1111-4111-8111-111111111111";
const ACCOUNT_B: &str = "22222222-2222-4222-8222-222222222222";
const CONNECTION: ConnectionId = ConnectionId(71);
const RPC_TIMEOUT: Duration = Duration::from_secs(15);

// Keyring's stock mock only persists within one Entry. AuthManager creates new
// entries when loading or refreshing, so share credentials by their store key.
type CredentialKey = (Option<String>, String, String);

struct MemoryCredentialBuilder {
    entries: Mutex<HashMap<CredentialKey, Arc<MockCredential>>>,
}

struct MemoryCredential(Arc<MockCredential>);

impl CredentialApi for MemoryCredential {
    fn set_secret(&self, secret: &[u8]) -> keyring::Result<()> {
        self.0.set_secret(secret)
    }

    fn get_secret(&self) -> keyring::Result<Vec<u8>> {
        self.0.get_secret()
    }

    fn delete_credential(&self) -> keyring::Result<()> {
        self.0.delete_credential()
    }

    fn as_any(&self) -> &dyn Any {
        self
    }
}

impl CredentialBuilderApi for MemoryCredentialBuilder {
    fn build(
        &self,
        target: Option<&str>,
        service: &str,
        user: &str,
    ) -> keyring::Result<Box<Credential>> {
        let key = (
            target.map(str::to_string),
            service.to_string(),
            user.to_string(),
        );
        let credential = self
            .entries
            .lock()
            .expect("memory credential store lock")
            .entry(key)
            .or_insert_with(|| Arc::new(MockCredential::default()))
            .clone();
        Ok(Box::new(MemoryCredential(credential)))
    }

    fn as_any(&self) -> &dyn Any {
        self
    }

    fn persistence(&self) -> CredentialPersistence {
        CredentialPersistence::ProcessOnly
    }
}

fn run_test(future: impl Future<Output = Result<()>>) -> Result<()> {
    for variable in [
        "CODEX_ACCESS_TOKEN",
        "OPENAI_FEDERATION_RULE_ID",
        "OPENAI_IDENTITY_TOKEN_FILE",
        "OPENAI_WORKLOAD_IDENTITY_CONTEXT",
    ] {
        anyhow::ensure!(
            std::env::var_os(variable).is_none(),
            "isolated turnrail tests require {variable} to be unset"
        );
    }
    static INSTALL_KEYRING: Once = Once::new();
    // Install before starting a runtime or reading any auth. No OS credential
    // builder is instantiated, including when the selected account is invalid.
    INSTALL_KEYRING.call_once(|| {
        keyring::set_default_credential_builder(Box::new(MemoryCredentialBuilder {
            entries: Mutex::new(HashMap::new()),
        }));
    });
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?
        .block_on(future)
}

struct RpcHarness {
    _codex_home: TempDir,
    turnrail_root: TempDir,
    server: MockServer,
    processor: Arc<MessageProcessor>,
    session: Arc<ConnectionSessionState>,
    messages: mpsc::UnboundedReceiver<OutgoingMessage>,
    notifications: VecDeque<ServerNotification>,
    next_request_id: i64,
}

impl RpcHarness {
    async fn new() -> Result<Self> {
        let codex_home = TempDir::new()?;
        let turnrail_root = TempDir::new()?;
        let server = MockServer::start().await;
        let mut model_catalog = codex_models_manager::bundled_models_response()?;
        let mut mock_model = model_catalog
            .models
            .first()
            .context("missing model fixture")?
            .clone();
        mock_model.slug = "mock-model".to_string();
        model_catalog.models.push(mock_model);
        Mock::given(method("GET"))
            .and(path("/v1/models"))
            .respond_with(ResponseTemplate::new(200).set_body_json(model_catalog))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/backend-api/wham/usage"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "plan_type": "pro",
                "rate_limit": {
                    "allowed": true,
                    "limit_reached": false,
                    "primary_window": {
                        "used_percent": 0,
                        "limit_window_seconds": 18_000,
                        "reset_after_seconds": 18_000,
                        "reset_at": 2_000_000_000
                    }
                }
            })))
            .mount(&server)
            .await;
        MockResponsesConfig::new(&server.uri())
            .with_provider_config("requires_openai_auth = true\nsupports_websockets = false")
            .with_root_config(&format!(
                "cli_auth_credentials_store = \"file\"\nchatgpt_base_url = \"{}/backend-api\"",
                server.uri()
            ))
            .disable_feature(Feature::SecretAuthStorage)
            .write(codex_home.path())?;
        // A distinct global credential makes an accidental restoration of the
        // process-wide AuthManager observable in the inference request.
        std::fs::write(
            codex_home.path().join("auth.json"),
            serde_json::to_vec(&json!({ "OPENAI_API_KEY": "global-token" }))?,
        )?;
        seed_account_auth(
            turnrail_root.path(),
            ACCOUNT_A,
            "a@example.com",
            "account-a",
        )?;
        seed_account_auth(
            turnrail_root.path(),
            ACCOUNT_B,
            "b@example.com",
            "account-b",
        )?;
        write_selection(turnrail_root.path(), ACCOUNT_A)?;
        let config = Arc::new(
            ConfigBuilder::default()
                .codex_home(codex_home.path().to_path_buf())
                .loader_overrides(LoaderOverrides::without_managed_config_for_tests())
                .build()
                .await?,
        );
        let state_db = codex_rollout::state_db::try_init(config.as_ref()).await?;
        let auth_manager = AuthManager::shared_from_config(
            config.as_ref(),
            /*enable_codex_api_key_env*/ false,
        )
        .await?;
        let config_manager = ConfigManager::new(
            config.codex_home.to_path_buf(),
            Vec::new(),
            LoaderOverrides::without_managed_config_for_tests(),
            /*strict_config*/ false,
            CloudConfigBundleLoader::default(),
            Arg0DispatchPaths::default(),
            Arc::new(codex_config::NoopThreadConfigLoader),
        );
        let (outgoing_tx, mut outgoing_rx) = mpsc::channel(64);
        let (messages_tx, messages) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            while let Some(envelope) = outgoing_rx.recv().await {
                let (message, write_complete_tx) = match envelope {
                    OutgoingEnvelope::ToConnection {
                        connection_id,
                        message,
                        write_complete_tx,
                    } => {
                        assert_eq!(connection_id, CONNECTION);
                        (message, write_complete_tx)
                    }
                    OutgoingEnvelope::Broadcast { message } => (message, None),
                };
                if messages_tx.send(message).is_err() {
                    break;
                }
                if let Some(write_complete_tx) = write_complete_tx {
                    let _ = write_complete_tx.send(());
                }
            }
        });
        let analytics_events_client = AnalyticsEventsClient::disabled();
        let outgoing = Arc::new(OutgoingMessageSender::new(
            outgoing_tx,
            analytics_events_client.clone(),
        ));
        let processor = Arc::new(MessageProcessor::new(MessageProcessorArgs {
            outgoing,
            analytics_events_client,
            arg0_paths: Arg0DispatchPaths::default(),
            config,
            config_manager,
            environment_manager: Arc::new(EnvironmentManager::default_for_tests()),
            feedback: CodexFeedback::new(),
            log_db: None,
            state_db: Some(state_db),
            config_warnings: Vec::new(),
            session_source: SessionSource::VSCode,
            auth_manager,
            installation_id: ACCOUNT_A.to_string(),
            code_mode_session_provider: None,
            rpc_transport: AppServerRpcTransport::Stdio,
            remote_control_handle: None,
            plugin_startup_tasks: None,
            turnrail_coordinator: Some(Arc::new(TurnrailCoordinator::from_root(
                turnrail_root.path().to_path_buf(),
            )?)),
        }));
        let mut harness = Self {
            _codex_home: codex_home,
            turnrail_root,
            server,
            processor,
            session: Arc::new(ConnectionSessionState::new()),
            messages,
            notifications: VecDeque::new(),
            next_request_id: 1,
        };
        let _: InitializeResponse = harness
            .request(
                "initialize",
                json!({
                    "clientInfo": { "name": "turnrail-rpc-tests", "version": "0.0.0" },
                    "capabilities": { "experimentalApi": true }
                }),
            )
            .await?;
        // The stdio transport registers the initialized connection separately
        // from JSON-RPC dispatch so thread listeners can subscribe to it.
        harness
            .processor
            .connection_initialized(CONNECTION, /*request_attestation*/ false)
            .await;
        Ok(harness)
    }

    async fn rpc(&mut self, method: &str, params: Value) -> Result<OutgoingMessage> {
        let request_id = RequestId::Integer(self.next_request_id);
        self.next_request_id += 1;
        tokio::time::timeout(
            RPC_TIMEOUT,
            self.processor.process_request(
                CONNECTION,
                JSONRPCRequest {
                    id: request_id.clone(),
                    method: method.to_string(),
                    params: Some(params),
                    trace: None,
                },
                &AppServerTransport::Stdio,
                Arc::clone(&self.session),
            ),
        )
        .await
        .with_context(|| format!("timed out processing RPC {method} ({request_id:?})"))?;
        loop {
            let message = tokio::time::timeout(RPC_TIMEOUT, self.messages.recv())
                .await
                .with_context(|| {
                    format!("timed out waiting for RPC response: {method} ({request_id:?})")
                })?
                .context("RPC output channel closed")?;
            match message {
                OutgoingMessage::AppServerNotification(envelope) => {
                    self.notifications.push_back(envelope.notification);
                }
                OutgoingMessage::Response(ref response) if response.id == request_id => {
                    return Ok(message);
                }
                OutgoingMessage::Error(ref error) if error.id == request_id => return Ok(message),
                other => anyhow::bail!("unexpected RPC output: {other:?}"),
            }
        }
    }

    async fn request<T: DeserializeOwned>(&mut self, method: &str, params: Value) -> Result<T> {
        match self.rpc(method, params).await? {
            OutgoingMessage::Response(response) => Ok(serde_json::from_value(
                serde_json::to_value(response.result)?,
            )?),
            other => anyhow::bail!("{method} failed: {other:?}"),
        }
    }

    async fn turn(
        &mut self,
        thread_id: &str,
        prompt: &str,
        token: &str,
        reply: &str,
    ) -> Result<(TurnCompletedNotification, ResponsesRequest)> {
        self.turn_with_params(
            json!({"threadId": thread_id, "input": [{"type": "text", "text": prompt}]}),
            token,
            reply,
        )
        .await
    }

    async fn turn_with_params(
        &mut self,
        params: Value,
        token: &str,
        reply: &str,
    ) -> Result<(TurnCompletedNotification, ResponsesRequest)> {
        let thread_id = params["threadId"]
            .as_str()
            .context("turn thread id")?
            .to_string();
        let response_id = format!("response-{}", self.next_request_id);
        let model = responses::mount_sse_once_match(
            &self.server,
            header("authorization", format!("Bearer {token}")),
            responses::sse(vec![
                responses::ev_response_created(&response_id),
                responses::ev_assistant_message(&format!("message-{response_id}"), reply),
                responses::ev_completed(&response_id),
            ]),
        )
        .await;
        let started: TurnStartResponse = self.request("turn/start", params).await?;
        let completed = self
            .wait_for_completion(&thread_id, &started.turn.id)
            .await?;
        let request = model.single_request();
        assert_eq!(
            request.header("authorization"),
            Some(format!("Bearer {token}"))
        );
        assert_eq!(request.header("thread-id"), Some(thread_id));
        Ok((completed, request))
    }

    async fn wait_for_completion(
        &mut self,
        thread_id: &str,
        turn_id: &str,
    ) -> Result<TurnCompletedNotification> {
        loop {
            let notification = match self.notifications.pop_front() {
                Some(notification) => notification,
                None => match tokio::time::timeout(RPC_TIMEOUT, self.messages.recv())
                    .await
                    .with_context(|| {
                        format!(
                            "timed out waiting for turn/completed: thread {thread_id}, turn {turn_id}"
                        )
                    })?
                    .context("turn output channel closed")?
                {
                    OutgoingMessage::AppServerNotification(envelope) => envelope.notification,
                    other => anyhow::bail!("unexpected turn output: {other:?}"),
                },
            };
            if let ServerNotification::TurnCompleted(completed) = notification
                && completed.thread_id == thread_id
                && completed.turn.id == turn_id
            {
                assert_eq!(completed.turn.status, TurnStatus::Completed);
                return Ok(completed);
            }
        }
    }

    async fn shutdown(self) {
        self.processor.shutdown_threads().await;
        self.processor.drain_background_tasks().await;
        self.processor.clear_runtime_references();
    }
}

#[path = "account_models_rpc_tests.rs"]
mod account_models_rpc_tests;

fn seed_account_auth(root: &Path, account_id: &str, email: &str, token: &str) -> Result<()> {
    seed_account_auth_fixture(
        root,
        account_id,
        ChatGptAuthFixture::new(token)
            .account_id(account_id)
            .email(email)
            .plan_type("pro"),
    )
}

fn seed_account_auth_fixture(
    root: &Path,
    account_id: &str,
    fixture: ChatGptAuthFixture,
) -> Result<()> {
    let auth_home = root.join("accounts").join(account_id).join("auth-home");
    std::fs::create_dir_all(&auth_home)?;
    write_chatgpt_auth(&auth_home, fixture, AuthCredentialsStoreMode::File)?;
    let auth: AuthDotJson = serde_json::from_slice(&std::fs::read(auth_home.join("auth.json"))?)?;
    save_auth(
        &auth_home,
        &auth,
        AuthCredentialsStoreMode::Keyring,
        AuthKeyringBackendKind::Direct,
    )?;
    Ok(())
}

fn write_selection(root: &Path, account_id: &str) -> Result<()> {
    std::fs::write(
        root.join("state.json"),
        serde_json::to_vec(&json!({
            "schemaVersion": 3,
            "revision": 1,
            "routing": { "defaultAccountIDs": [account_id], "directoryRules": [] },
            "accounts": [
                { "id": ACCOUNT_A, "email": "a@example.com", "planType": "pro" },
                { "id": ACCOUNT_B, "email": "b@example.com", "planType": "pro" }
            ]
        }))?,
    )?;
    Ok(())
}

fn conversation_messages(request: &ResponsesRequest) -> Vec<(String, String)> {
    request
        .input()
        .into_iter()
        .filter(|item| matches!(item["role"].as_str(), Some("user" | "assistant")))
        .flat_map(|item| {
            let role = item["role"].as_str().expect("message role").to_string();
            item["content"]
                .as_array()
                .expect("message content")
                .iter()
                .filter_map(|content| content["text"].as_str())
                .filter(|text| text.starts_with("fixture-"))
                .map(|text| (role.clone(), text.to_string()))
                .collect::<Vec<_>>()
        })
        .collect()
}

#[test]
fn thread_revert_preserves_selected_account_authentication() -> Result<()> {
    run_test(async {
        let mut harness = RpcHarness::new().await?;
        let started: ThreadStartResponse = harness
            .request("thread/start", json!({ "historyMode": "paginated" }))
            .await?;
        let thread_id = started.thread.id;
        harness
            .turn(
                &thread_id,
                "fixture-first",
                "account-a",
                "fixture-first-answer",
            )
            .await?;
        let (second, _) = harness
            .turn(
                &thread_id,
                "fixture-second",
                "account-a",
                "fixture-second-answer",
            )
            .await?;
        let reverted: ThreadRevertResponse = harness
            .request(
                "thread/revert",
                json!({
                    "threadId": thread_id,
                    "beforeTurnId": second.turn.id
                }),
            )
            .await?;
        assert_eq!(reverted.thread.id, thread_id);
        let (_, request) = harness
            .turn(
                &thread_id,
                "fixture-after-revert",
                "account-a",
                "fixture-after-revert-answer",
            )
            .await?;
        assert_eq!(
            conversation_messages(&request),
            vec![
                ("user".to_string(), "fixture-first".to_string()),
                ("assistant".to_string(), "fixture-first-answer".to_string()),
                ("user".to_string(), "fixture-after-revert".to_string()),
            ]
        );
        harness.shutdown().await;
        Ok(())
    })
}

#[test]
fn ephemeral_forks_switch_accounts_without_losing_memory_history() -> Result<()> {
    run_test(async {
        for history_mode in ["legacy", "paginated"] {
            let mut harness = RpcHarness::new().await?;
            let source: ThreadStartResponse = harness
                .request("thread/start", json!({ "historyMode": history_mode }))
                .await?;
            harness
                .turn(
                    &source.thread.id,
                    "fixture-source",
                    "account-a",
                    "fixture-source-answer",
                )
                .await?;
            let forked: ThreadForkResponse = harness
                .request(
                    "thread/fork",
                    json!({
                        "threadId": source.thread.id,
                        "ephemeral": true,
                        "excludeTurns": true
                    }),
                )
                .await?;
            let thread_id = forked.thread.id;
            assert!(forked.thread.ephemeral);
            assert_eq!(forked.thread.path, None);
            harness
                .turn(
                    &thread_id,
                    "fixture-fork-a",
                    "account-a",
                    "fixture-fork-a-answer",
                )
                .await?;
            write_selection(harness.turnrail_root.path(), ACCOUNT_B)?;
            let (_, request) = harness
                .turn(
                    &thread_id,
                    "fixture-fork-b",
                    "account-b",
                    "fixture-fork-b-answer",
                )
                .await?;
            assert_eq!(
                conversation_messages(&request),
                vec![
                    ("user".to_string(), "fixture-source".to_string()),
                    ("assistant".to_string(), "fixture-source-answer".to_string()),
                    ("user".to_string(), "fixture-fork-a".to_string()),
                    ("assistant".to_string(), "fixture-fork-a-answer".to_string()),
                    ("user".to_string(), "fixture-fork-b".to_string()),
                ]
            );
            let loaded: ThreadLoadedListResponse =
                harness.request("thread/loaded/list", json!({})).await?;
            assert!(loaded.data.contains(&thread_id));
            let read: ThreadReadResponse = harness
                .request("thread/read", json!({ "threadId": thread_id }))
                .await?;
            assert_eq!(read.thread.id, thread_id);
            assert!(read.thread.ephemeral);
            assert_eq!(read.thread.path, None);
            let listed: ThreadListResponse = harness.request("thread/list", json!({})).await?;
            assert!(listed.data.iter().all(|thread| thread.id != thread_id));
            harness.shutdown().await;
        }
        Ok(())
    })
}

#[test]
fn registry_email_mismatch_is_rejected_before_account_network_requests() -> Result<()> {
    run_test(async {
        let mut harness = RpcHarness::new().await?;
        seed_account_auth(
            harness.turnrail_root.path(),
            ACCOUNT_A,
            "b@example.com",
            "bad-token",
        )?;
        assert_identity_mismatch(&mut harness, "bad-token").await?;
        harness.shutdown().await;
        Ok(())
    })
}

async fn assert_identity_mismatch(harness: &mut RpcHarness, bad_token: &str) -> Result<()> {
    let response = harness.rpc("thread/start", json!({})).await?;
    let OutgoingMessage::Error(error) = response else {
        anyhow::bail!("mismatched account should fail thread/start: {response:?}");
    };
    assert!(
        error.error.message.contains("account identity mismatch:"),
        "{}",
        error.error.message
    );
    assert!(
        error.error.message.contains("a@example.com"),
        "{}",
        error.error.message
    );
    assert!(
        error.error.message.contains("b@example.com"),
        "{}",
        error.error.message
    );
    let requests = harness
        .server
        .received_requests()
        .await
        .context("captured backend requests")?;
    let bad_authorization = format!("Bearer {bad_token}");
    assert!(
        requests.iter().all(|request| {
            request
                .headers
                .get("authorization")
                .and_then(|value| value.to_str().ok())
                != Some(bad_authorization.as_str())
        }),
        "mismatched credentials must not reach the backend"
    );
    assert!(
        requests.iter().all(|request| {
            !request.url.path().ends_with("/responses")
                && !request.url.path().ends_with("/wham/usage")
        }),
        "identity mismatch must be rejected before usage or inference requests"
    );
    let loaded: ThreadLoadedListResponse = harness.request("thread/loaded/list", json!({})).await?;
    assert!(loaded.data.is_empty());
    Ok(())
}

#[test]
fn expired_registry_email_mismatch_does_not_refresh_authentication() -> Result<()> {
    const CHILD_ENV: &str = "CODEX_TURNRAIL_EXPIRED_AUTH_TEST_CHILD";
    const TEST_NAME: &str =
        "turnrail_rpc_tests::expired_registry_email_mismatch_does_not_refresh_authentication";
    match std::env::var(CHILD_ENV) {
        Ok(value) => {
            anyhow::ensure!(value == "1", "unexpected expired-auth child marker");
            let endpoint = std::env::var(REFRESH_TOKEN_URL_OVERRIDE_ENV_VAR)?;
            anyhow::ensure!(
                endpoint.starts_with("http://127.0.0.1:"),
                "expired-auth child requires the parent loopback refresh endpoint"
            );
            run_test(async {
                let mut harness = RpcHarness::new().await?;
                let expired_at = chrono::Utc::now() - chrono::Duration::days(30);
                let payload = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&json!({
                    "exp": expired_at.timestamp()
                }))?);
                let token = format!("e30.{payload}.signature");
                seed_account_auth_fixture(
                    harness.turnrail_root.path(),
                    ACCOUNT_A,
                    ChatGptAuthFixture::new(&token)
                        .account_id(ACCOUNT_A)
                        .email("b@example.com")
                        .plan_type("pro")
                        .last_refresh(Some(expired_at)),
                )?;
                assert_identity_mismatch(&mut harness, &token).await?;
                harness.shutdown().await;
                Ok(())
            })
        }
        Err(std::env::VarError::NotPresent) => run_test(async {
            let server = MockServer::start().await;
            Mock::given(method("POST"))
                .and(path("/oauth/token"))
                .respond_with(ResponseTemplate::new(401).set_body_json(json!({
                    "error": { "code": "refresh_token_invalidated" }
                })))
                .mount(&server)
                .await;
            // Set the existing login override before the child runtime starts.
            // Reusing this test binary avoids process-global env mutation and
            // lets the parent observe every attempted proactive refresh.
            let output = tokio::time::timeout(
                Duration::from_secs(45),
                tokio::process::Command::new(std::env::current_exe()?)
                    .args(["--exact", TEST_NAME, "--nocapture"])
                    .env(CHILD_ENV, "1")
                    .env(
                        REFRESH_TOKEN_URL_OVERRIDE_ENV_VAR,
                        format!("{}/oauth/token", server.uri()),
                    )
                    .kill_on_drop(true)
                    .output(),
            )
            .await
            .context("expired-auth child test timed out")??;
            let stdout = String::from_utf8_lossy(&output.stdout);
            let stderr = String::from_utf8_lossy(&output.stderr);
            anyhow::ensure!(
                output.status.success() && stdout.contains("1 passed; 0 failed"),
                "expired-auth child test failed: {}\nstdout:\n{stdout}\nstderr:\n{stderr}",
                output.status
            );
            let refresh_requests = server
                .received_requests()
                .await
                .context("captured refresh requests")?;
            assert!(
                refresh_requests.is_empty(),
                "identity mismatch must be rejected before proactive refresh: {refresh_requests:?}"
            );
            Ok(())
        }),
        Err(error) => Err(error.into()),
    }
}

#[test]
fn ephemeral_account_switch_retries_after_replacement_startup_failure() -> Result<()> {
    run_test(async {
        let mut harness = RpcHarness::new().await?;
        let started: ThreadStartResponse = harness
            .request("thread/start", json!({ "ephemeral": true }))
            .await?;
        let thread_id = started.thread.id;
        harness
            .turn(
                &thread_id,
                "fixture-before-failure",
                "account-a",
                "fixture-before-failure-answer",
            )
            .await?;

        let missing_command = harness
            ._codex_home
            .path()
            .join("missing-required-mcp-server");
        assert!(!missing_command.exists());
        let _: Value = harness
            .request(
                "config/batchWrite",
                json!({
                    "edits": [{
                        "keyPath": "mcp_servers.required_broken",
                        "value": {
                            "command": missing_command,
                            "required": true,
                            "startup_timeout_sec": 1
                        },
                        "mergeStrategy": "replace"
                    }],
                    "reloadUserConfig": true
                }),
            )
            .await?;
        write_selection(harness.turnrail_root.path(), ACCOUNT_B)?;
        let response = harness
            .rpc(
                "turn/start",
                json!({
                    "threadId": thread_id,
                    "input": [{ "type": "text", "text": "fixture-failed-switch" }]
                }),
            )
            .await?;
        let OutgoingMessage::Error(error) = response else {
            anyhow::bail!(
                "required MCP startup failure should reject account switch: {response:?}"
            );
        };
        assert!(
            error
                .error
                .message
                .contains("required MCP servers failed to initialize"),
            "{}",
            error.error.message
        );
        assert!(
            error.error.message.contains("required_broken"),
            "{}",
            error.error.message
        );
        let loaded: ThreadLoadedListResponse =
            harness.request("thread/loaded/list", json!({})).await?;
        assert!(
            loaded.data.contains(&thread_id),
            "failed replacement must retain the source thread"
        );
        let requests = harness
            .server
            .received_requests()
            .await
            .context("captured backend requests")?;
        assert_eq!(
            requests
                .iter()
                .filter(|request| request.url.path().ends_with("/responses"))
                .count(),
            1
        );

        let _: Value = harness
            .request(
                "config/batchWrite",
                json!({
                    "edits": [{
                        "keyPath": "mcp_servers.required_broken.enabled",
                        "value": false,
                        "mergeStrategy": "replace"
                    }],
                    "reloadUserConfig": true
                }),
            )
            .await?;
        let (_, request) = harness
            .turn(
                &thread_id,
                "fixture-retried-switch",
                "account-b",
                "fixture-retried-switch-answer",
            )
            .await?;
        assert_eq!(
            conversation_messages(&request),
            vec![
                ("user".to_string(), "fixture-before-failure".to_string()),
                (
                    "assistant".to_string(),
                    "fixture-before-failure-answer".to_string()
                ),
                ("user".to_string(), "fixture-retried-switch".to_string()),
            ]
        );
        let read: ThreadReadResponse = harness
            .request("thread/read", json!({ "threadId": thread_id }))
            .await?;
        assert_eq!(read.thread.id, thread_id);
        assert!(read.thread.ephemeral);
        assert_eq!(read.thread.path, None);
        harness.shutdown().await;
        Ok(())
    })
}
