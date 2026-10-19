import Foundation

/// Exposes bounded protocol diagnostics without forwarding server messages or request content.
struct RouterServiceFailure: LocalizedError, Sendable {
  enum Envelope: String, Codable, Sendable {
    case wrappedError, streamError, failedResponse, incompleteResponse
  }

  struct Field: Codable, Sendable {
    enum State: String, Codable, Sendable { case missing, null, invalid, unrecognized, recognized }
    let state: State
    let value: String?

    init(_ value: Any?) {
      switch value {
      case nil: state = .missing
      case is NSNull: state = .null
      case let text as String:
        state = RouterServiceFailure.identifiers.contains(text) ? .recognized : .unrecognized
      default: state = .invalid
      }
      self.value = state == .recognized ? value as? String : nil
    }

    var isAbsent: Bool { state == .missing || state == .null }
    var diagnostic: String { value ?? state.rawValue }
  }

  let eventType: String
  let envelope: Envelope
  let status: Int?
  let statusState: Field.State
  let errorType: Field
  let code: Field
  let reason: Field
  let retryDelay: RouterServiceRetryDelay
  private let summary: String
  var reference: String?
  var diagnosticWriteFailed = false
  var errorDescription: String? { description }

  init(event: [String: Any]) throws {
    let type = try RouterJSON.text(event, "type")
    let detail: [String: Any]
    switch type {
    case "error":
      if event["error"] != nil {
        guard event["code"] == nil, event["message"] == nil else {
          throw RouterFailure("The model service returned conflicting error envelopes.")
        }
        detail = try RouterJSON.map(event, "error")
        envelope = .wrappedError
      } else {
        // The Responses SSE error event places code/message directly on the event.
        guard event["code"] != nil || event["message"] is String else {
          throw RouterFailure("The model service returned an invalid stream error.")
        }
        detail = event.filter { $0.key != "type" }
        envelope = .streamError
      }
      summary = "The model service rejected the request."
    case "response.failed":
      detail = try RouterJSON.map(RouterJSON.map(event, "response"), "error")
      envelope = .failedResponse
      summary = "The model service could not complete the response."
    case "response.incomplete":
      let response = try RouterJSON.map(event, "response")
      if let details = response["incomplete_details"] as? [String: Any] {
        detail = details
      } else {
        detail = [:]
      }
      envelope = .incompleteResponse
      summary = "The model service returned an incomplete response."
    default:
      throw RouterFailure("Expected a terminal model-service failure.")
    }
    eventType = type
    if let value = event["status"] as? Int, (400...599).contains(value) {
      status = value
      statusState = .recognized
    } else {
      status = nil
      let field = Field(event["status"])
      statusState = field.isAbsent ? field.state : .invalid
    }
    errorType = Field(detail["type"])
    code = Field(detail["code"])
    reason = Field(detail["reason"])
    retryDelay = RouterServiceRetryDelay(headers: event["headers"], now: Date())
  }

  var isMisalignmentPolicyViolation: Bool {
    eventType != "response.incomplete" && code.value == "misalignment_policy_violation"
  }

  var isWebSocketConnectionLimit: Bool {
    envelope == .wrappedError && status == 400 && errorType.value == "invalid_request_error"
      && code.value == "websocket_connection_limit_reached"
  }

  /// Explicit transient status/type/code evidence is required; conflicting details stay terminal.
  var permitsEngineRecovery: Bool {
    guard eventType != "response.incomplete", reason.isAbsent, retryDelay.permitsRecovery else {
      return false
    }
    let temporaryStatus = status.map { [500, 502, 503, 504].contains($0) } == true
    let serverType = ["server_error", "service_unavailable_error"].contains(errorType.value)
    let serverCode = ["server_error", "server_is_overloaded"].contains(code.value)
    let absentStatus = statusState == .missing || statusState == .null
    return (temporaryStatus || absentStatus)
      && (serverType || errorType.isAbsent) && (serverCode || code.isAbsent)
      && (temporaryStatus || serverType || serverCode)
  }

  var description: String {
    var diagnostics = [eventType]
    if let status {
      diagnostics.append("HTTP \(status)")
    }
    let fields = [("type", errorType), ("code", code), ("reason", reason)]
    let recognized = fields.contains { $0.1.value != nil }
    if !recognized {
      diagnostics.append("reason unavailable or unrecognized")
    }
    for (name, field) in fields where !field.isAbsent || !recognized {
      diagnostics.append("\(name): \(field.diagnostic)")
    }
    switch retryDelay.state {
    case .missing, .null: break
    case .valid: diagnostics.append("Retry-After valid")
    case .invalid: diagnostics.append("invalid Retry-After")
    case .excessive: diagnostics.append("Retry-After exceeds the 60-second recovery budget")
    }
    if let reference { diagnostics.append("ref: \(reference)") }
    if diagnosticWriteFailed { diagnostics.append("diagnostic storage unavailable") }
    return
      summary + " [" + diagnostics.joined(separator: "; ") + "] "
      + (permitsEngineRecovery
        ? "Recovery is delegated to the official Engine using the bound account."
        : "This rejection will not be retried or moved to another account.")
  }

  /// Both official transports recognize this sanitized server error as retryable.
  func engineRecoveryEvent() throws -> [String: Any] {
    guard permitsEngineRecovery else {
      throw RouterFailure("This service failure does not permit Engine recovery.")
    }
    return [
      "type": "response.failed",
      "response": ["error": ["code": "server_error", "message": description]],
    ]
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
    "service_unavailable_error", "server_is_overloaded",
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
