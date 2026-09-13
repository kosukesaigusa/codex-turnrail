use super::*;
use pretty_assertions::assert_eq;

#[test]
fn last_used_tracks_real_turns_without_touching_other_accounts() -> Result<()> {
    run_test(async {
        let mut harness = RpcHarness::new().await?;
        let a_path = harness
            .turnrail_root
            .path()
            .join("accounts")
            .join(ACCOUNT_A)
            .join("last-used.json");
        let b_path = harness
            .turnrail_root
            .path()
            .join("accounts")
            .join(ACCOUNT_B)
            .join("last-used.json");
        let started: ThreadStartResponse = harness
            .request("thread/start", json!({ "historyMode": "paginated" }))
            .await?;
        let thread = started.thread.id;
        assert!(!a_path.exists());
        assert!(!b_path.exists());
        let rejected = harness
            .rpc(
                "turn/start",
                json!({
                    "threadId": thread,
                    "input": [{ "type": "text", "text": "fixture-rejected" }],
                    "toolOutput": { "name": "fixture", "output": "conflicting input" }
                }),
            )
            .await?;
        assert!(matches!(rejected, OutgoingMessage::Error(_)));
        assert!(!a_path.exists());

        let (first, _) = harness
            .turn(&thread, "fixture-a", "account-a", "fixture-answer-a")
            .await?;
        let a_bytes = std::fs::read(&a_path)?;
        let value: Value = serde_json::from_slice(&a_bytes)?;
        assert_eq!(
            value,
            json!({
                "schemaVersion": 1,
                "accountId": ACCOUNT_A,
                "startedAtUnixSeconds": first.turn.started_at.context("actual turn start timestamp")?
            })
        );
        assert!(!b_path.exists());

        write_selection(harness.turnrail_root.path(), ACCOUNT_B)?;
        // This harness has a global API key. The account read must still have
        // no effect on usage metadata, even when the read is rejected.
        let usage = harness.rpc("account/rateLimits/read", json!({})).await?;
        assert!(matches!(usage, OutgoingMessage::Error(_)));
        assert_eq!(std::fs::read(&a_path)?, a_bytes);
        assert!(!b_path.exists());
        let (second, _) = harness
            .turn(&thread, "fixture-b", "account-b", "fixture-answer-b")
            .await?;
        assert_eq!(std::fs::read(&a_path)?, a_bytes);
        let value: Value = serde_json::from_slice(&std::fs::read(&b_path)?)?;
        assert_eq!(
            value,
            json!({
                "schemaVersion": 1,
                "accountId": ACCOUNT_B,
                "startedAtUnixSeconds": second.turn.started_at.context("actual turn start timestamp")?
            })
        );
        harness.shutdown().await;
        Ok(())
    })
}
