use crate::session::tests::make_session_and_context_with_auth_and_config_and_rx;
use codex_history::InitialHistory;
use codex_history::RetainedContextEvent;
use codex_history::RolloutItem;
use codex_history::VerifiedAnswer;
use codex_history::VerifiedQuestionAnswer;
use codex_login::CodexAuth;
use pretty_assertions::assert_eq;

#[tokio::test]
async fn account_replacement_preserves_verified_user_answers() -> anyhow::Result<()> {
    let (source, _, _) = make_session_and_context_with_auth_and_config_and_rx(
        CodexAuth::from_api_key("source-account"),
        vec![],
        |config| config.ephemeral = true,
    )
    .await;
    let workspace = tempfile::tempdir()?;
    let workspace_root =
        codex_utils_absolute_path::AbsolutePathBuf::from_absolute_path(workspace.path())?;
    let retained = {
        let mut state = source.state.lock().await;
        state.session_configuration.runtime_workspace_roots = vec![workspace_root.clone()];
        assert!(
            state
                .history
                .record_retained_context(&RetainedContextEvent::VerifiedAnswer {
                    answer: VerifiedAnswer {
                        turn_id: "turn-before-switch".to_string(),
                        call_id: "user-answer".to_string(),
                        questions: vec![VerifiedQuestionAnswer {
                            question: "Where may the artifact be uploaded?".to_string(),
                            answer: "Keep it private.".to_string(),
                        }],
                    },
                    acceptance_order: None,
                })
        );
        state.history.retained_context().clone()
    };
    let InitialHistory::Resumed(resumed) = source.ephemeral_resume_history().await? else {
        anyhow::bail!("An account replacement must capture resumable history");
    };
    let metadata = resumed.history.iter().find_map(|item| match item {
        RolloutItem::SessionMeta(line) => Some(&line.meta),
        _ => None,
    });
    assert_eq!(
        metadata.and_then(|meta| meta.runtime_workspace_roots.as_ref()),
        Some(&vec![workspace_root.to_path_buf()])
    );
    let checkpoint = resumed.history.iter().find_map(|item| match item {
        RolloutItem::Compacted(checkpoint) => Some(checkpoint),
        _ => None,
    });
    assert_eq!(
        checkpoint.and_then(|item| item.retained_context.as_ref()),
        Some(&retained)
    );

    let (replacement, _, _) = make_session_and_context_with_auth_and_config_and_rx(
        CodexAuth::from_api_key("replacement-account"),
        vec![],
        |config| config.ephemeral = true,
    )
    .await;
    replacement.restore_ephemeral_context_from(&source).await;
    assert_eq!(
        replacement.state.lock().await.history.retained_context(),
        &retained
    );
    Ok(())
}
