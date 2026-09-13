use super::*;
use pretty_assertions::assert_eq;
use std::path::PathBuf;

const ACCOUNT_C: &str = "33333333-3333-4333-8333-333333333333";
const RULE_ID: &str = "44444444-4444-4444-8444-444444444444";

fn configure(
    harness: &RpcHarness,
    default_ids: &[&str],
    directory_ids: &[&str],
) -> Result<(PathBuf, PathBuf)> {
    let root = harness.turnrail_root.path().canonicalize()?;
    let work = root.join("projects/client");
    let personal = root.join("projects/personal");
    std::fs::create_dir_all(&work)?;
    std::fs::create_dir_all(&personal)?;
    seed_account_auth_fixture(
        &root,
        ACCOUNT_C,
        ChatGptAuthFixture::new("account-c")
            .account_id(ACCOUNT_C)
            .email("c@example.com")
            .plan_type("team"),
    )?;
    std::fs::write(
        root.join("state.json"),
        serde_json::to_vec(&json!({
            "schemaVersion": 3,
            "revision": 1,
            "accounts": [
                {"id": ACCOUNT_A, "email": "a@example.com", "planType": "pro"},
                {"id": ACCOUNT_B, "email": "b@example.com", "planType": "pro"},
                {"id": ACCOUNT_C, "email": "c@example.com", "planType": "team"}
            ],
            "routing": {
                "defaultAccountIDs": default_ids,
                "directoryRules": [{"id": RULE_ID, "directory": work, "accountIDs": directory_ids}]
            }
        }))?,
    )?;
    Ok((work, personal))
}

async fn start_at(harness: &mut RpcHarness, directory: &Path) -> Result<String> {
    let started: ThreadStartResponse = harness
        .request("thread/start", json!({"cwd": directory, "ephemeral": true}))
        .await?;
    Ok(started.thread.id)
}

#[test]
fn rule_priority_changes_apply_to_all_matching_conversations_on_their_next_turn() -> Result<()> {
    run_test(async {
        let mut harness = RpcHarness::new().await?;
        let (work, personal) = configure(
            &harness,
            &[ACCOUNT_A, ACCOUNT_B],
            &[ACCOUNT_C, ACCOUNT_A, ACCOUNT_B],
        )?;
        let first = start_at(&mut harness, &work).await?;
        let second = start_at(&mut harness, &work).await?;
        let outside = start_at(&mut harness, &personal).await?;
        harness
            .turn(&first, "fixture-first-c", "account-c", "fixture-c-answer")
            .await?;
        harness
            .turn(&second, "fixture-second-c", "account-c", "fixture-c-answer")
            .await?;
        harness
            .turn(
                &outside,
                "fixture-outside-a",
                "account-a",
                "fixture-a-answer",
            )
            .await?;
        configure(
            &harness,
            &[ACCOUNT_A, ACCOUNT_B],
            &[ACCOUNT_B, ACCOUNT_C, ACCOUNT_A],
        )?;
        let (_, request) = harness
            .turn(&first, "fixture-first-b", "account-b", "fixture-b-answer")
            .await?;
        assert_eq!(
            conversation_messages(&request),
            vec![
                ("user".to_string(), "fixture-first-c".to_string()),
                ("assistant".to_string(), "fixture-c-answer".to_string()),
                ("user".to_string(), "fixture-first-b".to_string())
            ]
        );
        harness
            .turn(&second, "fixture-second-b", "account-b", "fixture-b-answer")
            .await?;
        harness
            .turn(
                &outside,
                "fixture-still-outside-a",
                "account-a",
                "fixture-a-answer",
            )
            .await?;
        harness.shutdown().await;
        Ok(())
    })
}

async fn quota(harness: &RpcHarness, token: &str, used_percent: u64, priority: u8) {
    Mock::given(method("GET"))
        .and(path("/backend-api/wham/usage"))
        .and(header("authorization", format!("Bearer {token}")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "plan_type": "pro",
            "rate_limit": {
                "allowed": used_percent < 100,
                "limit_reached": used_percent == 100,
                "primary_window": {
                    "used_percent": used_percent, "limit_window_seconds": 18_000,
                    "reset_after_seconds": 18_000, "reset_at": 2_000_000_000
                }
            }
        })))
        .with_priority(priority)
        .mount(&harness.server)
        .await;
}

#[test]
fn quota_fallback_uses_only_permitted_accounts_and_never_probes_an_excluded_account() -> Result<()>
{
    run_test(async {
        let mut harness = RpcHarness::new().await?;
        let (work, personal) = configure(
            &harness,
            &[ACCOUNT_A, ACCOUNT_B],
            &[ACCOUNT_C, ACCOUNT_A, ACCOUNT_B],
        )?;
        quota(&harness, "account-c", 100, 2).await;
        let inside = start_at(&mut harness, &work).await?;
        harness
            .turn(
                &inside,
                "fixture-fallback-a",
                "account-a",
                "fixture-a-answer",
            )
            .await?;
        quota(&harness, "account-c", 0, 1).await;
        quota(&harness, "account-a", 100, 1).await;
        quota(&harness, "account-b", 100, 1).await;
        let before = harness
            .server
            .received_requests()
            .await
            .context("requests")?
            .len();
        let response = harness
            .rpc("thread/start", json!({"cwd": personal}))
            .await?;
        let OutgoingMessage::Error(error) = response else {
            anyhow::bail!("exhausted permitted accounts must block");
        };
        assert!(
            error
                .error
                .message
                .contains("no Codex Turnrail account is available")
        );
        let requests = harness
            .server
            .received_requests()
            .await
            .context("requests")?;
        let headers: Vec<_> = requests[before..]
            .iter()
            .filter_map(|request| {
                request
                    .headers
                    .get("authorization")
                    .and_then(|value| value.to_str().ok())
            })
            .collect();
        assert_eq!(headers, vec!["Bearer account-a", "Bearer account-b"]);
        harness.shutdown().await;
        Ok(())
    })
}

#[test]
fn turn_cwd_overrides_and_thread_cwd_updates_reselect_the_account() -> Result<()> {
    run_test(async {
        let mut harness = RpcHarness::new().await?;
        let (work, personal) = configure(&harness, &[ACCOUNT_A], &[ACCOUNT_C])?;
        let thread = start_at(&mut harness, &work).await?;
        harness
            .turn(&thread, "fixture-in-work", "account-c", "fixture-c-answer")
            .await?;
        harness
            .turn_with_params(
                json!({
                    "threadId": thread, "cwd": personal,
                    "input": [{"type": "text", "text": "fixture-moved-outside"}]
                }),
                "account-a",
                "fixture-a-answer",
            )
            .await?;
        harness
            .turn(
                &thread,
                "fixture-remains-outside",
                "account-a",
                "fixture-a-answer",
            )
            .await?;
        harness
            .turn_with_params(
                json!({
                    "threadId": thread, "environments": [{"environmentId": "local", "cwd": work}],
                    "input": [{"type": "text", "text": "fixture-local-environment-work"}]
                }),
                "account-c",
                "fixture-c-answer",
            )
            .await?;
        harness.turn_with_params(json!({
            "threadId": thread, "environments": [{"environmentId": "local", "cwd": personal}],
            "input": [{"type": "text", "text": "fixture-local-environment-personal"}]
        }), "account-a", "fixture-a-answer").await?;
        let _: Value = harness
            .request(
                "thread/settings/update",
                json!({"threadId": thread, "cwd": work}),
            )
            .await?;
        harness
            .turn(
                &thread,
                "fixture-back-in-work",
                "account-c",
                "fixture-c-answer",
            )
            .await?;
        configure(&harness, &[ACCOUNT_A], &[])?;
        let before = harness
            .server
            .received_requests()
            .await
            .context("requests")?
            .len();
        let response = harness
            .rpc(
                "turn/start",
                json!({
                    "threadId": thread, "input": [{"type": "text", "text": "fixture-blocked"}]
                }),
            )
            .await?;
        let OutgoingMessage::Error(error) = response else {
            anyhow::bail!("empty directory rule must block the existing conversation");
        };
        assert!(error.error.message.contains("no accounts are allowed"));
        assert_eq!(
            harness
                .server
                .received_requests()
                .await
                .context("requests")?
                .len(),
            before
        );
        harness.shutdown().await;
        Ok(())
    })
}

#[test]
fn changing_priority_during_a_turn_preserves_its_account_until_completion() -> Result<()> {
    run_test(async {
        let mut harness = RpcHarness::new().await?;
        let (work, _) = configure(&harness, &[ACCOUNT_A], &[ACCOUNT_C, ACCOUNT_B])?;
        let thread = start_at(&mut harness, &work).await?;
        let pending = Mock::given(method("POST"))
            .and(wiremock::matchers::path_regex(".*/responses$"))
            .and(header("authorization", "Bearer account-c"))
            .respond_with(
                responses::sse_response(responses::sse(vec![
                    responses::ev_response_created("active-c"),
                    responses::ev_assistant_message("message-c", "fixture-active-c-answer"),
                    responses::ev_completed("active-c"),
                ]))
                .set_delay(Duration::from_secs(2)),
            )
            .up_to_n_times(1)
            .expect(1)
            .mount_as_scoped(&harness.server)
            .await;
        let started: TurnStartResponse = harness
            .request(
                "turn/start",
                json!({
                    "threadId": thread, "input": [{"type": "text", "text": "fixture-active-c"}]
                }),
            )
            .await?;
        tokio::time::timeout(RPC_TIMEOUT, pending.wait_until_satisfied()).await?;
        configure(&harness, &[ACCOUNT_A], &[ACCOUNT_B, ACCOUNT_C])?;
        let completed = harness
            .wait_for_completion(&thread, &started.turn.id)
            .await?;
        assert_eq!(completed.turn.status, TurnStatus::Completed);
        drop(pending);
        harness
            .turn(
                &thread,
                "fixture-after-active-b",
                "account-b",
                "fixture-b-answer",
            )
            .await?;
        harness.shutdown().await;
        Ok(())
    })
}
