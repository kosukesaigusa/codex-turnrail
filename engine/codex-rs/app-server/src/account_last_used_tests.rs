use super::*;
use crate::turnrail::TurnrailCoordinator;
use codex_protocol::ThreadId;
use serde_json::json;

#[test]
fn concurrent_writers_keep_the_latest_timestamp_per_account() -> Result<()> {
    let root = tempfile::tempdir()?;
    let a = Uuid::new_v4();
    let b = Uuid::new_v4();
    for account in [a, b] {
        std::fs::create_dir_all(root.path().join("accounts").join(account.to_string()))?;
    }
    std::thread::scope(|scope| {
        for timestamp in [200, 100, 300, 250] {
            let path = root.path();
            scope.spawn(move || record(path, a, timestamp).unwrap());
        }
        let path = root.path();
        scope.spawn(move || record(path, b, 150).unwrap());
    });
    for (account, timestamp) in [(a, 300), (b, 150)] {
        let value: serde_json::Value = serde_json::from_slice(&std::fs::read(
            root.path()
                .join("accounts")
                .join(account.to_string())
                .join("last-used.json"),
        )?)?;
        assert_eq!(
            value,
            json!({
                "schemaVersion": 1,
                "accountId": account,
                "startedAtUnixSeconds": timestamp
            })
        );
    }
    Ok(())
}

#[test]
fn invalid_records_are_not_overwritten_and_removed_accounts_are_not_recreated() -> Result<()> {
    let root = tempfile::tempdir()?;
    let account = Uuid::new_v4();
    let directory = root.path().join("accounts").join(account.to_string());
    std::fs::create_dir_all(&directory)?;
    let path = directory.join("last-used.json");
    for bytes in [
        "{".to_string(),
        json!({"schemaVersion": 2, "accountId": account, "startedAtUnixSeconds": 100}).to_string(),
        json!({"schemaVersion": 1, "accountId": Uuid::new_v4(), "startedAtUnixSeconds": 100})
            .to_string(),
        json!({"schemaVersion": 1, "accountId": account, "startedAtUnixSeconds": -1}).to_string(),
    ] {
        std::fs::write(&path, &bytes)?;
        assert!(record(root.path(), account, 200).is_err());
        assert_eq!(std::fs::read_to_string(&path)?, bytes);
    }
    std::fs::remove_dir_all(&directory)?;
    assert!(record(root.path(), account, 200).is_err());
    assert!(!directory.exists());
    Ok(())
}

#[tokio::test]
async fn unowned_threads_are_ignored_and_missing_start_times_are_errors() -> Result<()> {
    let root = tempfile::tempdir()?;
    let coordinator = TurnrailCoordinator::from_root(root.path().to_path_buf())?;
    let thread = ThreadId::new();
    coordinator
        .record_turn_started(thread, /*started_at*/ None)
        .await?;
    coordinator.record_owner(thread, Uuid::new_v4()).await;
    assert!(
        coordinator
            .record_turn_started(thread, /*started_at*/ None)
            .await
            .is_err()
    );
    assert_eq!(std::fs::read_dir(root.path())?.count(), 0);
    Ok(())
}
