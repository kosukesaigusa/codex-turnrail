use codex_exec_server::LOCAL_FS;
use codex_git_utils::get_git_repo_root;
use codex_git_utils::resolve_root_git_project_for_trust;
use codex_utils_absolute_path::AbsolutePathBuf;
use serde::Deserialize;
use std::collections::HashSet;
use std::path::Component;
use std::path::PathBuf;
use uuid::Uuid;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct AccountRouting {
    #[serde(rename = "defaultAccountIDs")]
    default_account_ids: Vec<Uuid>,
    directory_rules: Vec<DirectoryAccountRule>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DirectoryAccountRule {
    id: Uuid,
    directory: PathBuf,
    #[serde(rename = "accountIDs")]
    account_ids: Vec<Uuid>,
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum AccountRoutingError {
    #[error("directory routing contains duplicate rule id {0}")]
    DuplicateRule(Uuid),
    #[error("directory routing requires a normalized absolute directory: {0}")]
    InvalidDirectory(PathBuf),
    #[error("directory routing contains duplicate directory {0}")]
    DuplicateDirectory(PathBuf),
    #[error("directory routing refers to unknown account {0}")]
    UnknownAccount(Uuid),
    #[error("directory routing contains duplicate account {0} in a rule")]
    DuplicateAccount(Uuid),
    #[error("failed to resolve routing directory {path}: {source}")]
    ResolveDirectory {
        path: PathBuf,
        source: std::io::Error,
    },
    #[error("no accounts are allowed by the routing rule for {0}")]
    NoAllowedAccounts(PathBuf),
}

impl AccountRouting {
    pub(crate) fn all_assigned_account_ids(&self) -> HashSet<Uuid> {
        self.default_account_ids
            .iter()
            .chain(
                self.directory_rules
                    .iter()
                    .flat_map(|rule| rule.account_ids.iter()),
            )
            .copied()
            .collect()
    }

    pub(crate) fn validate(
        &self,
        known_account_ids: &HashSet<Uuid>,
    ) -> Result<(), AccountRoutingError> {
        let mut rule_ids = HashSet::new();
        let mut directories = HashSet::new();
        for rule in &self.directory_rules {
            if !rule_ids.insert(rule.id) {
                return Err(AccountRoutingError::DuplicateRule(rule.id));
            }
            if !rule.directory.is_absolute()
                || rule
                    .directory
                    .components()
                    .any(|component| matches!(component, Component::ParentDir | Component::CurDir))
            {
                return Err(AccountRoutingError::InvalidDirectory(
                    rule.directory.clone(),
                ));
            }
            if !directories.insert(&rule.directory) {
                return Err(AccountRoutingError::DuplicateDirectory(
                    rule.directory.clone(),
                ));
            }
        }
        for ids in std::iter::once(&self.default_account_ids)
            .chain(self.directory_rules.iter().map(|rule| &rule.account_ids))
        {
            let mut seen = HashSet::new();
            for id in ids {
                if !known_account_ids.contains(id) {
                    return Err(AccountRoutingError::UnknownAccount(*id));
                }
                if !seen.insert(*id) {
                    return Err(AccountRoutingError::DuplicateAccount(*id));
                }
            }
        }
        Ok(())
    }

    pub(crate) async fn ordered_account_ids(
        &self,
        cwd: &AbsolutePathBuf,
    ) -> Result<&[Uuid], AccountRoutingError> {
        let directory = routing_directory(cwd).await?;
        let ids = match self
            .directory_rules
            .iter()
            .filter(|rule| directory.starts_with(&rule.directory))
            .max_by_key(|rule| rule.directory.components().count())
        {
            Some(rule) => &rule.account_ids,
            None => &self.default_account_ids,
        };
        if ids.is_empty() {
            return Err(AccountRoutingError::NoAllowedAccounts(directory));
        }
        Ok(ids)
    }
}

/// Linked worktrees use the verified main checkout, preserving subdirectories.
///
/// Without a verified origin, only the actual directory can select a rule.
async fn routing_directory(cwd: &AbsolutePathBuf) -> Result<PathBuf, AccountRoutingError> {
    let canonical = tokio::fs::canonicalize(cwd).await.map_err(|source| {
        AccountRoutingError::ResolveDirectory {
            path: cwd.to_path_buf(),
            source,
        }
    })?;
    let canonical_cwd = AbsolutePathBuf::from_absolute_path(&canonical)
        .map_err(|_| AccountRoutingError::InvalidDirectory(canonical.clone()))?;
    if let Some(checkout) = get_git_repo_root(&canonical)
        && let Some(main_checkout) =
            resolve_root_git_project_for_trust(LOCAL_FS.as_ref(), &canonical_cwd).await
        && let Ok(relative) = canonical.strip_prefix(&checkout)
    {
        let main = tokio::fs::canonicalize(&main_checkout)
            .await
            .map_err(|source| AccountRoutingError::ResolveDirectory {
                path: main_checkout.to_path_buf(),
                source,
            })?;
        return Ok(main.join(relative));
    }
    Ok(canonical)
}

#[cfg(test)]
#[path = "account_routing_tests.rs"]
mod tests;
