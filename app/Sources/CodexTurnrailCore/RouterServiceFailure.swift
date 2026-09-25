import Foundation

/// Exposes bounded protocol diagnostics without forwarding server messages or request content.
struct RouterServiceFailure: LocalizedError, Sendable {
  let description: String
  let isMisalignmentPolicyViolation: Bool
  let isWebSocketConnectionLimit: Bool
  var errorDescription: String? { description }

  init(event: [String: Any]) throws {
    let type = try RouterJSON.text(event, "type")
    let detail: [String: Any]
    let summary: String
    switch type {
    case "error":
      detail = try RouterJSON.map(event, "error")
      summary = "The model service rejected the request."
    case "response.failed":
      detail = try RouterJSON.map(RouterJSON.map(event, "response"), "error")
      summary = "The model service could not complete the response."
    case "response.incomplete":
      let response = try RouterJSON.map(event, "response")
      if let details = response["incomplete_details"] as? [String: Any] {
        detail = details
      } else {
        detail = [:]
      }
      summary = "The model service returned an incomplete response."
    default:
      throw RouterFailure("Expected a terminal model-service failure.")
    }
    isMisalignmentPolicyViolation =
      type != "response.incomplete" && detail["code"] as? String == "misalignment_policy_violation"
    isWebSocketConnectionLimit =
      type == "error" && event["status"] as? Int == 400
      && detail["type"] as? String == "invalid_request_error"
      && detail["code"] as? String == "websocket_connection_limit_reached"
    var diagnostics = [type]
    if let status = event["status"] as? Int, (400...599).contains(status) {
      diagnostics.append("HTTP \(status)")
    }
    var recognized = false
    for field in ["type", "code", "reason"] {
      if let value = detail[field] as? String, Self.identifiers.contains(value) {
        diagnostics.append("\(field): \(value)")
        recognized = true
      }
    }
    if !recognized { diagnostics.append("reason unavailable or unrecognized") }
    description =
      summary + " [" + diagnostics.joined(separator: "; ") + "] "
      + "No account switch or inference replay was attempted."
  }

  /// Retains the official Engine's retry classification without exposing server text or headers.
  static var connectionLimitRetryEvent: [String: Any] {
    [
      "type": "error", "status": 400,
      "error": [
        "type": "invalid_request_error", "code": "websocket_connection_limit_reached",
        "message": "The WebSocket connection expired. Reconnect using the bound account.",
      ],
    ]
  }

  // Only protocol-defined identifiers may enter the desktop error and saved rollout.
  // Free-form messages, unknown identifiers, headers and content remain private.
  private static let identifiers: Set<String> = [
    "invalid_request_error", "authentication_error", "permission_error", "server_error",
    "context_length_exceeded", "invalid_encrypted_content", "invalid_prompt", "invalid_value",
    "invalid_argument", "invalid_parameter", "missing_required_parameter", "unsupported_parameter",
    "previous_response_not_found", "model_not_found", "invalid_api_key", "token_revoked",
    "insufficient_permissions", "permission_denied", "rate_limit_exceeded", "usage_limit_reached",
    "workspace_member_usage_limit_reached", "usage_not_included", "insufficient_quota",
    "credit_balance_exhausted", "organization_spend_limit_exceeded", "project_spend_limit_exceeded",
    "organization_usage_limit_exceeded", "server_overloaded", "internal_error", "slow_down",
    "websocket_connection_limit_reached", "websocket_timeout", "max_output_tokens",
    "max_tool_calls",
    "content_filter", "cyber_policy", "bio_policy", "misalignment_policy_violation",
  ]
}
