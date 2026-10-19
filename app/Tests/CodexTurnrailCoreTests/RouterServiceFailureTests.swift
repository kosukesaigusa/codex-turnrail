import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterServiceFailureTests {
  @Test(arguments: [500, 502, 503, 504])
  func temporaryHTTPFailuresCanRecoverWithoutAnOptionalReasonCode(status: Int) throws {
    for detail: [String: Any] in [
      [:], ["type": "server_error"],
      ["type": "service_unavailable_error", "code": NSNull()],
    ] {
      let failure = try RouterServiceFailure(event: [
        "type": "error", "status": status, "error": detail,
      ])
      #expect(failure.permitsEngineRecovery)
    }
  }

  @Test
  func documentedStreamFailuresRecoverWithoutAnHTTPErrorEnvelope() throws {
    for code in ["server_error", "server_is_overloaded"] {
      for event: [String: Any] in [
        ["type": "error", "error": ["code": code]],
        ["type": "error", "code": code, "message": "PRIVATE_SERVER_TEXT"],
        ["type": "response.failed", "response": ["error": ["code": code]]],
      ] {
        let failure = try RouterServiceFailure(event: event)
        #expect(failure.permitsEngineRecovery)
        #expect(failure.localizedDescription.contains(code))
        #expect(try !RouterJSON.string(failure.engineRecoveryEvent()).contains("PRIVATE_"))
      }
    }
    let overload = try RouterServiceFailure(event: [
      "type": "error", "status": 503,
      "error": ["type": "service_unavailable_error", "code": "server_is_overloaded"],
    ])
    #expect(overload.permitsEngineRecovery)
    #expect(overload.localizedDescription.contains("service_unavailable_error"))
  }

  @Test(arguments: [500, 503])
  func recognizedServerErrorsRetainTheEngineRetryClassificationWithoutPrivateDetails(status: Int)
    throws
  {
    for event: [String: Any] in [
      [
        "type": "error", "status": status,
        "error": [
          "type": "server_error", "code": "server_error", "message": "PRIVATE_SERVER_TEXT",
          "authorization": "PRIVATE_TOKEN", "account_id": "PRIVATE_ACCOUNT",
        ],
      ],
      [
        "type": "response.failed",
        "response": ["error": ["code": "server_error", "message": "PRIVATE_SERVER_TEXT"]],
      ],
    ] {
      let failure = try RouterServiceFailure(event: event)
      #expect(failure.permitsEngineRecovery)
      #expect(!failure.isMisalignmentPolicyViolation)
      #expect(!failure.isWebSocketConnectionLimit)
      #expect(!failure.localizedDescription.contains("will not be retried"))
      let recovered = try failure.engineRecoveryEvent()
      #expect(recovered["type"] as? String == "response.failed")
      #expect(
        try RouterJSON.map(RouterJSON.map(recovered, "response"), "error")["code"] as? String
          == "server_error")
      #expect(try !RouterJSON.string(recovered).contains("PRIVATE_"))
    }
  }

  @Test
  func otherServiceFailuresCannotCreateRetryEvents() throws {
    for event: [String: Any] in [
      ["type": "error", "status": 400, "error": ["type": "server_error", "code": "server_error"]],
      [
        "type": "error", "status": 503,
        "error": ["type": "server_error", "code": "usage_limit_reached"],
      ],
      [
        "type": "error", "status": 503,
        "error": ["type": "permission_error", "code": "server_error"],
      ],
      [
        "type": "error", "status": 503,
        "error": ["type": "server_error", "code": "misalignment_policy_violation"],
      ],
      [
        "type": "error", "status": 500, "error": ["type": "server_error", "code": "unknown_error"],
      ],
      [
        "type": "error", "status": 500,
        "error": ["type": "server_error", "code": "usage_limit_reached"],
      ],
      [
        "type": "error", "status": 500,
        "error": ["type": "invalid_request_error", "code": "misalignment_policy_violation"],
      ],
      ["type": "response.failed", "response": ["error": ["code": "token_revoked"]]],
      [
        "type": "response.failed",
        "response": ["error": ["code": "server_error", "type": "permission_error"]],
      ],
      [
        "type": "response.incomplete", "response": ["incomplete_details": ["code": "server_error"]],
      ],
    ] {
      let failure = try RouterServiceFailure(event: event)
      #expect(!failure.permitsEngineRecovery)
      #expect(failure.localizedDescription.contains("will not be retried"))
      #expect(throws: (any Error).self) { try failure.engineRecoveryEvent() }
    }
  }

  @Test
  func temporaryStatusesCannotOverrideTerminalUnknownOrMalformedDetails() throws {
    for code in [
      "token_revoked", "usage_limit_reached", "insufficient_quota", "context_length_exceeded",
      "invalid_prompt", "misalignment_policy_violation", "cyber_policy", "bio_policy",
      "PRIVATE_UNKNOWN_CODE",
    ] {
      for status in [500, 502, 503, 504] {
        let failure = try RouterServiceFailure(event: [
          "type": "error", "status": status,
          "error": ["type": "server_error", "code": code],
        ])
        #expect(!failure.permitsEngineRecovery)
        #expect(!failure.localizedDescription.contains("PRIVATE_"))
      }
    }
    for detail: [String: Any] in [
      ["code": 42], ["type": 42], ["reason": "content_filter"],
      ["type": "permission_error", "code": "server_error"],
      ["type": "PRIVATE_TYPE", "code": "server_error"],
    ] {
      let failure = try RouterServiceFailure(event: [
        "type": "error", "status": 503, "error": detail,
      ])
      #expect(!failure.permitsEngineRecovery)
    }
    for status: Any in [400, 401, 403, 429, 501, 200, "503", true] {
      let failure = try RouterServiceFailure(event: [
        "type": "error", "status": status, "error": ["code": "server_is_overloaded"],
      ])
      #expect(!failure.permitsEngineRecovery)
    }
  }

  @Test
  func flatPolicyErrorsStayTerminalAndConflictingEnvelopesAreRejected() throws {
    let failure = try RouterServiceFailure(event: [
      "type": "error", "code": "misalignment_policy_violation", "message": "PRIVATE_TEXT",
    ])
    #expect(failure.isMisalignmentPolicyViolation)
    #expect(!failure.permitsEngineRecovery)
    #expect(!failure.localizedDescription.contains("PRIVATE_"))
    #expect(throws: (any Error).self) {
      try RouterServiceFailure(event: [
        "type": "error", "code": "server_error",
        "error": ["code": "misalignment_policy_violation"],
      ])
    }
  }

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
