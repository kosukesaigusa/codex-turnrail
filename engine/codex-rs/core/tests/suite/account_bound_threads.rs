use codex_core::CodexThread;
use codex_core::StartThreadOptions;
use codex_core::TurnInputRequest;
use codex_login::CodexAuth;
use codex_protocol::mcp::ClientMcpExtensions;
use codex_protocol::protocol::EventMsg;
use codex_protocol::user_input::UserInput;
use core_test_support::responses::ev_assistant_message;
use core_test_support::responses::ev_completed;
use core_test_support::responses::ev_response_created;
use core_test_support::responses::mount_response_once_match;
use core_test_support::responses::mount_sse_once_match;
use core_test_support::responses::sse;
use core_test_support::responses::sse_response;
use core_test_support::test_codex::test_codex;
use core_test_support::wait_for_event;
use pretty_assertions::assert_eq;
use std::time::Duration;
use tokio::time::timeout;
use wiremock::MockServer;
use wiremock::matchers::header;

async fn submit_text(thread: &CodexThread, prompt: &str) -> anyhow::Result<()> {
    thread
        .start_or_steer_turn(TurnInputRequest::user_input(vec![UserInput::Text {
            text: prompt.to_string(),
            text_elements: Vec::new(),
        }]))
        .await?;
    wait_for_event(thread, |event| matches!(event, EventMsg::TurnComplete(_))).await;
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn parallel_threads_keep_their_bound_auth_while_one_is_in_flight() -> anyhow::Result<()> {
    let server = MockServer::start().await;
    let account_a_response = mount_response_once_match(
        &server,
        header("authorization", "Bearer account-a"),
        sse_response(sse(vec![
            ev_response_created("response-a"),
            ev_completed("response-a"),
        ]))
        .set_delay(Duration::from_millis(250)),
    )
    .await;
    let account_b_response = mount_sse_once_match(
        &server,
        header("authorization", "Bearer account-b"),
        sse(vec![
            ev_response_created("response-b"),
            ev_completed("response-b"),
        ]),
    )
    .await;

    let mut builder = test_codex().with_auth(CodexAuth::from_api_key("account-a"));
    let account_a = builder.build(&server).await?;
    let account_b_auth = codex_core::test_support::auth_manager_from_auth_with_home(
        CodexAuth::from_api_key("account-b"),
        account_a.config.codex_home.to_path_buf(),
    );
    let account_b = account_a
        .thread_manager
        .start_thread_with_auth_manager(
            StartThreadOptions::new(account_a.config.clone()),
            account_b_auth,
        )
        .await?;

    account_a
        .codex
        .start_or_steer_turn(TurnInputRequest::user_input(vec![UserInput::Text {
            text: "account A turn".to_string(),
            text_elements: Vec::new(),
        }]))
        .await?;
    timeout(Duration::from_secs(5), async {
        while account_a_response.requests().is_empty() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("account A request should become in-flight");

    account_b
        .thread
        .start_or_steer_turn(TurnInputRequest::user_input(vec![UserInput::Text {
            text: "account B turn".to_string(),
            text_elements: Vec::new(),
        }]))
        .await?;

    tokio::join!(
        wait_for_event(&account_a.codex, |event| matches!(
            event,
            EventMsg::TurnComplete(_)
        )),
        wait_for_event(&account_b.thread, |event| matches!(
            event,
            EventMsg::TurnComplete(_)
        )),
    );

    let account_a_request = account_a_response.single_request();
    let account_b_request = account_b_response.single_request();
    assert_eq!(
        account_a_request.header("authorization").as_deref(),
        Some("Bearer account-a")
    );
    assert_eq!(
        account_b_request.header("authorization").as_deref(),
        Some("Bearer account-b")
    );
    assert_ne!(
        account_a_request.header("thread-id"),
        account_b_request.header("thread-id")
    );

    account_a
        .thread_manager
        .shutdown_all_threads_bounded(Duration::from_secs(10))
        .await;
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn idle_thread_resumes_with_new_auth_and_preserves_history() -> anyhow::Result<()> {
    let server = MockServer::start().await;
    let account_a_response = mount_sse_once_match(
        &server,
        header("authorization", "Bearer account-a"),
        sse(vec![
            ev_response_created("response-a"),
            ev_assistant_message("message-a", "reply from account A"),
            ev_completed("response-a"),
        ]),
    )
    .await;
    let account_b_response = mount_sse_once_match(
        &server,
        header("authorization", "Bearer account-b"),
        sse(vec![
            ev_response_created("response-b"),
            ev_completed("response-b"),
        ]),
    )
    .await;

    let mut builder = test_codex().with_auth(CodexAuth::from_api_key("account-a"));
    let account_a = builder.build(&server).await?;
    let thread_id = account_a.session_configured.thread_id;
    let rollout_path = account_a
        .session_configured
        .rollout_path
        .clone()
        .expect("persisted rollout path");
    submit_text(&account_a.codex, "first turn on account A").await?;
    account_a.codex.ensure_rollout_materialized().await;
    account_a.codex.flush_rollout().await?;
    account_a.codex.shutdown_and_wait().await?;
    account_a.thread_manager.remove_thread(&thread_id).await;

    let account_b_auth = codex_core::test_support::auth_manager_from_auth_with_home(
        CodexAuth::from_api_key("account-b"),
        account_a.config.codex_home.to_path_buf(),
    );
    let account_b = account_a
        .thread_manager
        .resume_thread_from_rollout(
            account_a.config.clone(),
            rollout_path,
            account_b_auth,
            /*parent_trace*/ None,
            ClientMcpExtensions::default(),
        )
        .await?;
    assert_eq!(account_b.thread_id, thread_id);

    submit_text(&account_b.thread, "second turn on account B").await?;

    let account_a_request = account_a_response.single_request();
    let account_b_request = account_b_response.single_request();
    assert_eq!(
        account_a_request.header("authorization").as_deref(),
        Some("Bearer account-a")
    );
    assert_eq!(
        account_b_request.header("authorization").as_deref(),
        Some("Bearer account-b")
    );
    let conversation_turns = account_b_request
        .message_input_texts("user")
        .into_iter()
        .filter(|text| !text.starts_with("<environment_context>"))
        .collect::<Vec<_>>();
    assert_eq!(
        conversation_turns,
        vec![
            "first turn on account A".to_string(),
            "second turn on account B".to_string(),
        ]
    );
    assert_eq!(
        account_b_request.header("thread-id"),
        Some(thread_id.to_string())
    );

    account_b.thread.shutdown_and_wait().await?;
    account_a.thread_manager.remove_thread(&thread_id).await;
    Ok(())
}
