use anyhow::Context;
use anyhow::Result;
use codex_core::TurnInputRequest;
use codex_protocol::models::PermissionProfile;
use codex_protocol::protocol::AskForApproval;
use codex_protocol::protocol::EventMsg;
use codex_protocol::protocol::ExecCommandStatus;
use codex_protocol::protocol::Op;
use codex_protocol::protocol::ReviewDecision;
use codex_protocol::user_input::UserInput;
use core_test_support::responses::ev_assistant_message;
use core_test_support::responses::ev_completed;
use core_test_support::responses::ev_function_call;
use core_test_support::responses::ev_response_created;
use core_test_support::responses::mount_sse_once;
use core_test_support::responses::sse;
use core_test_support::responses::start_mock_server;
use core_test_support::zsh_fork::zsh_fork_runtime;
use core_test_support::zsh_fork::zsh_fork_test_builder;
use pretty_assertions::assert_eq;
use serde_json::json;
#[cfg(unix)]
use std::os::unix::process::CommandExt;
#[cfg(unix)]
use std::process::Command;
use std::time::Duration;
use test_case::test_case;

#[test_case(ReviewDecision::denied("declined"), ExecCommandStatus::Declined, 17, Duration::ZERO; "decline")]
#[test_case(ReviewDecision::denied("declined"), ExecCommandStatus::Declined, 17, Duration::from_millis(500); "background_decline")]
#[test_case(ReviewDecision::Abort, ExecCommandStatus::Declined, 17, Duration::from_millis(500); "background_cancel")]
#[test_case(ReviewDecision::Approved, ExecCommandStatus::Failed, 17, Duration::ZERO; "command_failure")]
#[test_case(ReviewDecision::Approved, ExecCommandStatus::Completed, 0, Duration::ZERO; "success")]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn intercepted_approval_preserves_command_status(
    decision: ReviewDecision,
    expected_status: ExecCommandStatus,
    command_exit: i32,
    approval_delay: Duration,
) -> Result<()> {
    let runtime = zsh_fork_runtime("command status regression")?
        .context("zsh-fork runtime is required for the command status regression")?;
    let server = start_mock_server().await;
    let test = zsh_fork_test_builder(runtime, AskForApproval::UnlessTrusted)
        .with_config(|config| {
            config
                .permissions
                .set_permission_profile(PermissionProfile::Disabled)
                .expect("set test permission profile");
        })
        .build(&server)
        .await?;
    let target = test.cwd.path().join("approval-target.txt");
    std::fs::write(&target, "keep until approved")?;
    let command = format!("/bin/rm {target:?}; printf after-approval; exit {command_exit}");
    let call_id = "intercepted-status";
    mount_sse_once(
        &server,
        sse(vec![
            ev_response_created("response-1"),
            ev_function_call(
                call_id,
                "exec_command",
                &json!({"cmd": command, "yield_time_ms": 20000}).to_string(),
            ),
            ev_completed("response-1"),
        ]),
    )
    .await;
    let follow_up = mount_sse_once(
        &server,
        sse(vec![
            ev_response_created("response-2"),
            ev_assistant_message("message-1", "done"),
            ev_completed("response-2"),
        ]),
    )
    .await;
    test.codex
        .start_or_steer_turn(TurnInputRequest::user_input(vec![UserInput::Text {
            text: "run the command".to_string(),
            text_elements: Vec::new(),
        }]))
        .await?;

    let mut subcommand_approvals = 0;
    let mut completion = None;
    let mut turn_completed = false;
    tokio::time::timeout(Duration::from_secs(20), async {
        while completion.is_none() || !turn_completed {
            match test.codex.next_event().await?.msg {
                EventMsg::ExecApprovalRequest(approval) => {
                    let approval_decision = if approval.approval_id.is_some() {
                        assert!(
                            approval
                                .command
                                .iter()
                                .any(|arg| arg == &target.to_string_lossy())
                        );
                        subcommand_approvals += 1;
                        tokio::time::sleep(approval_delay).await;
                        decision.clone()
                    } else {
                        ReviewDecision::Approved
                    };
                    test.codex
                        .submit(Op::ExecApproval {
                            id: approval.effective_approval_id(),
                            turn_id: None,
                            decision: approval_decision,
                        })
                        .await?;
                }
                EventMsg::ExecCommandEnd(event) if event.call_id == call_id => {
                    assert!(completion.is_none(), "command must complete exactly once");
                    completion = Some(event);
                }
                EventMsg::TurnComplete(_) | EventMsg::TurnAborted(_) => turn_completed = true,
                _ => {}
            }
        }
        Ok::<(), anyhow::Error>(())
    })
    .await??;

    let completion = completion.context("command completion")?;
    assert_eq!(subcommand_approvals, 1);
    assert_eq!(completion.status, expected_status);
    if decision == ReviewDecision::Abort {
        assert_ne!(completion.exit_code, 0);
    } else {
        assert_eq!(completion.exit_code, command_exit);
        assert!(completion.aggregated_output.contains("after-approval"));
        assert_eq!(follow_up.requests().len(), 1);
    }
    assert_eq!(
        target.exists(),
        expected_status == ExecCommandStatus::Declined
    );
    Ok(())
}

#[cfg(unix)]
#[test]
fn intercepted_command_reports_transport_failure_without_executing() -> Result<()> {
    let output = Command::new(codex_utils_cargo_bin::cargo_bin("codex")?)
        .arg0("codex-execve-wrapper")
        .args(["/bin/echo", "echo", "COMMAND_MUST_NOT_RUN"])
        .env_clear()
        .env("CODEX_ESCALATE_SOCKET", "-1")
        .output()?;

    assert_eq!(output.status.code(), Some(1));
    assert_eq!(output.stdout, Vec::<u8>::new());
    assert_eq!(
        String::from_utf8(output.stderr)?,
        "Failed to execute intercepted command: CODEX_ESCALATE_SOCKET is not a valid file descriptor: -1\n"
    );
    Ok(())
}
