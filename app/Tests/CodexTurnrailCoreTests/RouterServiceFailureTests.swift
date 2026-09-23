import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterServiceFailureTests {
  @Test
  func safetyStopUsesTheProtocolCodeWithoutExposingPrivateDetails() throws {
    let detail: [String: Any] = [
      "code": "misalignment_policy_violation", "message": "private request content",
      "misalignment": ["detailed_explanation": "private account@example.com"],
    ]
    for event: [String: Any] in [
      ["type": "error", "error": detail],
      ["type": "response.failed", "response": ["error": detail]],
    ] {
      let error = try RouterServiceFailure(event: event)
      #expect(error.isMisalignmentPolicyViolation)
      #expect(!error.localizedDescription.contains("private"))
    }
    let unclassified = try RouterServiceFailure(event: [
      "type": "error", "error": ["message": "misalignment_policy_violation"],
    ])
    #expect(!unclassified.isMisalignmentPolicyViolation)
    let incomplete = try RouterServiceFailure(event: [
      "type": "response.incomplete", "response": ["incomplete_details": detail],
    ])
    #expect(!incomplete.isMisalignmentPolicyViolation)
  }

  @Test
  func quotaRejectionRetainsStatusAndReasonWithoutForwardingAccountDetails() throws {
    let error = try RouterServiceFailure(event: [
      "type": "error", "status": 429,
      "error": [
        "type": "usage_limit_reached", "message": "private account@example.com",
        "account_id": "private-workspace", "authorization": "Bearer private-token",
      ],
    ])
    #expect(error.localizedDescription.contains("HTTP 429"))
    #expect(error.localizedDescription.contains("usage_limit_reached"))
    #expect(!error.localizedDescription.contains("private"))
  }

  @Test
  func inputFailureAndIncompleteOutputRemainDifferentDiagnoses() throws {
    let failed = try RouterServiceFailure(event: [
      "type": "response.failed",
      "response": [
        "error": ["code": "context_length_exceeded", "message": "private input"],
        "output": [["text": "private output"]],
      ],
    ])
    let incomplete = try RouterServiceFailure(event: [
      "type": "response.incomplete",
      "response": ["incomplete_details": ["reason": "max_output_tokens"]],
    ])
    #expect(failed.localizedDescription.contains("context_length_exceeded"))
    #expect(incomplete.localizedDescription.contains("incomplete response"))
    #expect(incomplete.localizedDescription.contains("max_output_tokens"))
    #expect(!incomplete.localizedDescription.contains("rejected"))
    #expect(!failed.localizedDescription.contains("private"))
  }

  @Test
  func unknownOrMissingDiagnosticsStayExplicitWithoutExposingArbitraryStrings() throws {
    for detail: [String: Any] in [
      [:], ["code": "secret_token_123", "type": "private-workspace", "message": "private input"],
      ["code": 42, "message": "Bearer private-token"],
    ] {
      let error = try RouterServiceFailure(event: ["type": "error", "error": detail])
      #expect(error.localizedDescription.contains("reason unavailable or unrecognized"))
      #expect(!error.localizedDescription.contains("secret"))
      #expect(!error.localizedDescription.contains("private"))
    }
    let error = try RouterServiceFailure(event: [
      "type": "response.incomplete", "response": ["incomplete_details": NSNull()],
    ])
    #expect(error.localizedDescription.contains("reason unavailable or unrecognized"))
    #expect(throws: (any Error).self) {
      try RouterServiceFailure(event: ["type": "response.completed"])
    }
  }
}
