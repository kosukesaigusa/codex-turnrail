use super::*;
use codex_app_server_protocol::ModelListResponse;
use codex_protocol::openai_models::ModelInfo;
use codex_protocol::openai_models::ModelVisibility;
use pretty_assertions::assert_eq;

fn assign(harness: &RpcHarness, ids: &[&str]) -> Result<()> {
    let path = harness.turnrail_root.path().join("state.json");
    let mut state: Value = serde_json::from_slice(&std::fs::read(&path)?)?;
    state["routing"]["defaultAccountIDs"] = json!(ids);
    std::fs::write(path, serde_json::to_vec(&state)?)?;
    Ok(())
}

async fn catalog(harness: &RpcHarness, token: &str, models: Vec<ModelInfo>) {
    Mock::given(method("GET"))
        .and(path("/v1/models"))
        .and(header("authorization", format!("Bearer {token}")))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"models": models})))
        .with_priority(1)
        .mount(&harness.server)
        .await;
}

#[test]
fn lists_only_models_shared_by_assigned_accounts_and_reloads_assignments() -> Result<()> {
    run_test(async {
        let mut harness = RpcHarness::new().await?;
        assign(&harness, &[ACCOUNT_A, ACCOUNT_B])?;
        let template = codex_models_manager::bundled_models_response()?
            .models
            .remove(0);
        let make_model = |slug: &str| {
            let mut model = template.clone();
            model.slug = slug.to_string();
            model.visibility = ModelVisibility::List;
            model
        };
        catalog(
            &harness,
            "account-a",
            vec![make_model("shared"), make_model("only-a")],
        )
        .await;
        catalog(
            &harness,
            "account-b",
            vec![make_model("shared"), make_model("only-b")],
        )
        .await;
        let listed: ModelListResponse = harness.request("model/list", json!({})).await?;
        assert_eq!(
            listed
                .data
                .iter()
                .map(|model| model.model.as_str())
                .collect::<Vec<_>>(),
            vec!["shared"]
        );
        assert_eq!(listed.next_cursor, None);
        assert!(listed.data[0].is_default);

        let previous_requests = harness
            .server
            .received_requests()
            .await
            .context("missing request capture")?
            .len();
        assign(&harness, &[ACCOUNT_B])?;
        let first: ModelListResponse = harness.request("model/list", json!({"limit": 1})).await?;
        let second: ModelListResponse = harness
            .request(
                "model/list",
                json!({"limit": 1, "cursor": first.next_cursor}),
            )
            .await?;
        assert_eq!(first.data[0].model, "shared");
        assert_eq!(second.data[0].model, "only-b");
        assert_eq!(second.next_cursor, None);
        let requests = harness
            .server
            .received_requests()
            .await
            .context("missing request capture")?;
        assert!(
            requests[previous_requests..]
                .iter()
                .filter(|request| request.url.path() == "/v1/models")
                .all(|request| {
                    request
                        .headers
                        .get("authorization")
                        .is_some_and(|value| value == "Bearer account-b")
                })
        );
        assert!(
            requests
                .iter()
                .filter(|request| request.url.path() == "/v1/models")
                .all(|request| {
                    request.headers.get("authorization").is_some_and(|value| {
                        value == "Bearer account-a" || value == "Bearer account-b"
                    })
                })
        );
        harness.shutdown().await;
        Ok(())
    })
}

#[test]
fn a_model_fetch_failure_is_an_error_instead_of_a_global_or_cached_catalog() -> Result<()> {
    run_test(async {
        let mut harness = RpcHarness::new().await?;
        let _: ModelListResponse = harness.request("model/list", json!({})).await?;
        Mock::given(method("GET"))
            .and(path("/v1/models"))
            .and(header("authorization", "Bearer account-a"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"models": "broken"})))
            .with_priority(1)
            .up_to_n_times(1)
            .expect(1)
            .mount(&harness.server)
            .await;
        let failed = harness.rpc("model/list", json!({})).await?;
        let OutgoingMessage::Error(error) = failed else {
            anyhow::bail!("expected model error");
        };
        assert!(
            error
                .error
                .message
                .contains("Could not fetch models for account")
        );
        let _: ModelListResponse = harness.request("model/list", json!({})).await?;
        harness.shutdown().await;
        Ok(())
    })
}

#[test]
fn a_model_missing_from_the_next_account_rejects_the_turn_without_replacing_history() -> Result<()>
{
    run_test(async {
        let mut harness = RpcHarness::new().await?;
        let started: ThreadStartResponse = harness
            .request("thread/start", json!({"ephemeral": true}))
            .await?;
        harness
            .turn(
                &started.thread.id,
                "fixture-before-model-check",
                "account-a",
                "fixture-kept-answer",
            )
            .await?;
        write_selection(harness.turnrail_root.path(), ACCOUNT_B)?;
        catalog(&harness, "account-b", Vec::new()).await;
        let failed = harness
            .rpc(
                "turn/start",
                json!({
                    "threadId": started.thread.id,
                    "input": [{"type": "text", "text": "fixture-rejected-model-turn"}]
                }),
            )
            .await?;
        let OutgoingMessage::Error(error) = failed else {
            anyhow::bail!("expected model rejection");
        };
        assert!(
            error
                .error
                .message
                .contains("is not available for the selected account")
        );
        write_selection(harness.turnrail_root.path(), ACCOUNT_A)?;
        let (_, request) = harness
            .turn(
                &started.thread.id,
                "fixture-after-model-check",
                "account-a",
                "fixture-final-answer",
            )
            .await?;
        assert_eq!(
            conversation_messages(&request),
            vec![
                ("user".to_string(), "fixture-before-model-check".to_string()),
                ("assistant".to_string(), "fixture-kept-answer".to_string()),
                ("user".to_string(), "fixture-after-model-check".to_string()),
            ]
        );
        harness.shutdown().await;
        Ok(())
    })
}
