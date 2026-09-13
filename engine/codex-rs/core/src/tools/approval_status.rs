use codex_protocol::protocol::NetworkPolicyRuleAction;
use codex_protocol::protocol::ReviewDecision;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::Ordering;

/// Shares an intercepted command's approval outcome with its process completion.
///
/// Recording before interrupting the turn preserves cancellation even when the
/// task waiting for the approval response is dropped.
#[derive(Clone, Debug)]
pub(crate) struct ExecApprovalStatus(Arc<AtomicBool>);

impl ExecApprovalStatus {
    pub(crate) fn new() -> Self {
        Self(Arc::new(AtomicBool::new(false)))
    }

    pub(crate) fn record(&self, decision: &ReviewDecision) {
        if matches!(
            decision,
            ReviewDecision::Denied { .. } | ReviewDecision::Abort
        ) || matches!(
            decision,
            ReviewDecision::NetworkPolicyAmendment { network_policy_amendment }
                if network_policy_amendment.action == NetworkPolicyRuleAction::Deny
        ) {
            self.0.store(true, Ordering::Relaxed);
        }
    }

    pub(crate) fn declined(&self) -> bool {
        self.0.load(Ordering::Relaxed)
    }
}

impl PartialEq for ExecApprovalStatus {
    fn eq(&self, other: &Self) -> bool {
        // Approval actions share an outcome only when they belong to the same command.
        Arc::ptr_eq(&self.0, &other.0)
    }
}
