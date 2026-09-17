use super::session::Session;
use codex_history::CompactedItem;
use codex_history::InitialHistory;
use codex_history::ResumedHistory;
use codex_history::RolloutItem;
use codex_protocol::error::CodexErr;
use codex_protocol::error::Result as CodexResult;
use codex_protocol::models::BaseInstructions;
use codex_protocol::protocol::SessionMeta;
use codex_protocol::protocol::SessionMetaLine;
use codex_rollout::RolloutConfigView;
use std::sync::Arc;

#[cfg(test)]
#[path = "ephemeral_resume_tests.rs"]
mod tests;

impl Session {
    /// Captures the startup metadata and model context of an ephemeral session.
    ///
    /// The caller must first stop the session so its history cannot change during replacement.
    pub(crate) async fn ephemeral_resume_history(&self) -> CodexResult<InitialHistory> {
        let state = self.state.lock().await;
        let configuration = &state.session_configuration;
        let config = &configuration.original_config_do_not_use;
        if !config.ephemeral {
            return Err(CodexErr::InvalidRequest(
                "in-memory account switching requires an ephemeral thread".to_string(),
            ));
        }
        let source = configuration.session_source.clone();
        let window = state.auto_compact_window_ids();
        let meta = SessionMeta {
            session_id: self.session_id(),
            id: self.thread_id,
            forked_from_id: configuration.forked_from_thread_id,
            forked_from_ordinal_exclusive: self.forked_from_ordinal_exclusive,
            parent_thread_id: configuration.parent_thread_id,
            timestamp: chrono::Utc::now().to_rfc3339(),
            cwd: configuration.cwd().to_path_buf(),
            runtime_workspace_roots: Some(
                configuration
                    .runtime_workspace_roots
                    .iter()
                    .map(codex_utils_absolute_path::AbsolutePathBuf::to_path_buf)
                    .collect(),
            ),
            originator: configuration.originator.clone(),
            cli_version: env!("CARGO_PKG_VERSION").to_string(),
            agent_nickname: source.get_nickname(),
            agent_role: source.get_agent_role(),
            agent_path: source.get_agent_path().map(Into::into),
            source,
            thread_source: configuration.thread_source.clone(),
            model_provider: Some(config.model_provider_id().to_string()),
            base_instructions: Some(BaseInstructions {
                text: configuration.base_instructions.clone(),
                provenance: state.base_instructions_provenance.clone(),
            }),
            dynamic_tools: Some(configuration.dynamic_tools.clone()),
            selected_capability_roots: self.services.selected_capability_roots.clone(),
            memory_mode: (!config.generate_memories()).then_some("disabled".to_string()),
            history_mode: configuration.history_mode,
            history_base: None,
            subagent_history_start_ordinal: None,
            multi_agent_version: self.multi_agent_version.get().copied(),
            context_window: None,
        };
        let checkpoint = CompactedItem {
            message: String::new(),
            replacement_history: Some(state.history.annotated_items().to_vec()),
            retained_context: Some(state.history.retained_context().clone()),
            guardian_history: state.history.guardian_history_checkpoint(),
            mcp_resource_origins: self.services.mcp_runtime.resource_origin_checkpoint(),
            window_number: Some(state.auto_compact_window_number()),
            first_window_id: Some(window.first_window_id.to_string()),
            previous_window_id: window.previous_window_id.map(|id| id.to_string()),
            window_id: Some(window.window_id.to_string()),
            compaction_response_id: None,
            latest_token_usage_record: state.latest_token_usage_record.clone(),
        };
        Ok(InitialHistory::Resumed(ResumedHistory {
            conversation_id: self.thread_id,
            history: Arc::new(vec![
                RolloutItem::SessionMeta(SessionMetaLine { meta, git: None }),
                RolloutItem::Compacted(checkpoint),
            ]),
            rollout_path: None,
        }))
    }

    /// Restores exact in-memory context after the new authenticated services have started.
    pub(crate) async fn restore_ephemeral_context_from(&self, source: &Self) {
        let snapshot = source.state.lock().await.ephemeral_context_snapshot();
        self.state.lock().await.restore_ephemeral_context(snapshot);
    }
}
