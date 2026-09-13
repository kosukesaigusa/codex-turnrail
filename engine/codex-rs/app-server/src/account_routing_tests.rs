use super::*;
use anyhow::Result;
use pretty_assertions::assert_eq;
use serde_json::json;
use std::path::Path;

const A: &str = "11111111-1111-4111-8111-111111111111";
const B: &str = "22222222-2222-4222-8222-222222222222";
const C: &str = "33333333-3333-4333-8333-333333333333";
const RULE: &str = "44444444-4444-4444-8444-444444444444";
const NESTED: &str = "55555555-5555-4555-8555-555555555555";

fn routing(directory: &Path) -> Result<AccountRouting> {
    Ok(serde_json::from_value(json!({
        "defaultAccountIDs": [A, B],
        "directoryRules": [
            {"id": RULE, "directory": directory, "accountIDs": [C, A, B]},
            {"id": NESTED, "directory": directory.join("nested"), "accountIDs": [B]}
        ]
    }))?)
}

async fn selected(routing: &AccountRouting, cwd: &Path) -> Result<Vec<String>> {
    let cwd = AbsolutePathBuf::from_absolute_path(cwd)?;
    Ok(routing
        .ordered_account_ids(&cwd)
        .await?
        .iter()
        .map(Uuid::to_string)
        .collect())
}

#[tokio::test]
async fn selects_the_deepest_component_match_or_explicit_default_rule() -> Result<()> {
    let temp = tempfile::tempdir()?;
    let root = temp.path().canonicalize()?;
    let scope = root.join("work");
    let routing = routing(&scope)?;
    for (relative, expected) in [
        ("work", vec![C, A, B]),
        ("work/project", vec![C, A, B]),
        ("work/nested/project", vec![B]),
        ("work-other", vec![A, B]),
        ("personal", vec![A, B]),
    ] {
        let cwd = root.join(relative);
        std::fs::create_dir_all(&cwd)?;
        assert_eq!(selected(&routing, &cwd).await?, expected);
    }
    Ok(())
}

#[tokio::test]
async fn empty_rules_and_unresolvable_directories_fail_without_other_candidates() -> Result<()> {
    let temp = tempfile::tempdir()?;
    let root = temp.path().canonicalize()?;
    let scope = root.join("blocked");
    std::fs::create_dir_all(&scope)?;
    let routing: AccountRouting = serde_json::from_value(json!({
        "defaultAccountIDs": [A],
        "directoryRules": [{"id": RULE, "directory": scope, "accountIDs": []}]
    }))?;
    let scope = AbsolutePathBuf::from_absolute_path(scope)?;
    assert!(matches!(
        routing.ordered_account_ids(&scope).await,
        Err(AccountRoutingError::NoAllowedAccounts(_))
    ));
    let missing = AbsolutePathBuf::from_absolute_path(root.join("missing"))?;
    assert!(matches!(
        routing.ordered_account_ids(&missing).await,
        Err(AccountRoutingError::ResolveDirectory { .. })
    ));
    let empty: AccountRouting =
        serde_json::from_value(json!({"defaultAccountIDs": [], "directoryRules": []}))?;
    let root = AbsolutePathBuf::from_absolute_path(root)?;
    assert!(matches!(
        empty.ordered_account_ids(&root).await,
        Err(AccountRoutingError::NoAllowedAccounts(_))
    ));
    Ok(())
}

#[test]
fn rejects_unknown_duplicate_and_ambiguous_configuration() -> Result<()> {
    let temp = tempfile::tempdir()?;
    let root = temp.path().canonicalize()?;
    let known = [Uuid::parse_str(A)?, Uuid::parse_str(B)?]
        .into_iter()
        .collect();
    for value in [
        json!({"defaultAccountIDs": [C], "directoryRules": []}),
        json!({"defaultAccountIDs": [A, A], "directoryRules": []}),
        json!({"defaultAccountIDs": [A], "directoryRules": [{"id": RULE, "directory": "relative", "accountIDs": [B]}]}),
        json!({"defaultAccountIDs": [A], "directoryRules": [{"id": RULE, "directory": root.join("../other"), "accountIDs": [B]}]}),
        json!({"defaultAccountIDs": [A], "directoryRules": [
            {"id": RULE, "directory": root, "accountIDs": [B]},
            {"id": RULE, "directory": root.join("child"), "accountIDs": [B]}
        ]}),
        json!({"defaultAccountIDs": [A], "directoryRules": [
            {"id": RULE, "directory": root, "accountIDs": [B]},
            {"id": NESTED, "directory": root, "accountIDs": [A]}
        ]}),
    ] {
        let routing: AccountRouting = serde_json::from_value(value)?;
        assert!(routing.validate(&known).is_err());
    }
    for value in [
        json!({"directoryRules": []}),
        json!({"defaultAccountIDs": [A]}),
        json!({"defaultAccountIDs": [A], "directoryRules": [], "unknown": true}),
    ] {
        assert!(serde_json::from_value::<AccountRouting>(value).is_err());
    }
    Ok(())
}

#[cfg(unix)]
#[tokio::test]
async fn symlinks_use_the_actual_directory_in_both_directions() -> Result<()> {
    let temp = tempfile::tempdir()?;
    let root = temp.path().canonicalize()?;
    let scope = root.join("work");
    let outside = root.join("personal");
    std::fs::create_dir_all(&scope)?;
    std::fs::create_dir_all(&outside)?;
    std::os::unix::fs::symlink(&scope, root.join("alias"))?;
    std::os::unix::fs::symlink(&outside, scope.join("external"))?;
    let routing = routing(&scope)?;
    assert_eq!(
        selected(&routing, &root.join("alias")).await?,
        vec![C, A, B]
    );
    assert_eq!(
        selected(&routing, &scope.join("external")).await?,
        vec![A, B]
    );
    Ok(())
}

#[tokio::test]
async fn linked_worktrees_inherit_only_a_verified_origin_and_preserve_subdirectory_rules()
-> Result<()> {
    let temp = tempfile::tempdir()?;
    let root = temp.path().canonicalize()?;
    let project = root.join("work");
    let checkout = root.join("worktree");
    let metadata = project.join(".git/worktrees/feature");
    std::fs::create_dir_all(&metadata)?;
    std::fs::create_dir_all(checkout.join("nested/child"))?;
    std::fs::write(project.join(".git/HEAD"), "ref: refs/heads/main\n")?;
    std::fs::write(
        checkout.join(".git"),
        format!("gitdir: {}\n", metadata.display()),
    )?;
    std::fs::write(metadata.join("commondir"), "../..\n")?;
    std::fs::write(
        metadata.join("gitdir"),
        format!("{}\n", checkout.join(".git").display()),
    )?;
    let routing = routing(&project)?;
    assert_eq!(selected(&routing, &checkout).await?, vec![C, A, B]);
    assert_eq!(
        selected(&routing, &checkout.join("nested/child")).await?,
        vec![B]
    );
    // A pointer alone cannot claim another project's rule: ownership must match.
    std::fs::write(
        metadata.join("gitdir"),
        format!("{}\n", root.join("different/.git").display()),
    )?;
    assert_eq!(selected(&routing, &checkout).await?, vec![A, B]);
    Ok(())
}
