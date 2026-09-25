import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterConnectionLimitTests {
  @Test
  func onlyTheExplicitPreResponseRejectionIsRecoverable() throws {
    let detail: [String: Any] = [
      "type": "invalid_request_error", "code": "websocket_connection_limit_reached",
      "message": "PRIVATE_SERVER_TEXT", "account_id": "PRIVATE_ACCOUNT",
    ]
    let event: [String: Any] = ["type": "error", "status": 400, "error": detail]
    #expect(try RouterServiceFailure(event: event).isWebSocketConnectionLimit)
    for other: [String: Any] in [
      ["type": "response.failed", "status": 400, "response": ["error": detail]],
      ["type": "response.incomplete", "status": 400, "response": ["incomplete_details": detail]],
      ["type": "error", "status": 429, "error": detail],
      ["type": "error", "error": detail],
      ["type": "error", "status": 400, "error": ["message": "websocket_connection_limit_reached"]],
    ] {
      #expect(try !RouterServiceFailure(event: other).isWebSocketConnectionLimit)
    }
    let forwarded = RouterServiceFailure.connectionLimitRetryEvent
    #expect(try RouterServiceFailure(event: forwarded).isWebSocketConnectionLimit)
    #expect(try !RouterJSON.string(forwarded).contains("PRIVATE_"))
  }

  @Test
  func rejectedRequestPermitsOneResubmissionWithoutChangingItsBinding() throws {
    let root = try RouterTestDirectory()
    let ledger = try RouterLedger(root: root.url)
    let account = UUID()
    try ledger.bind("thread/turn", account: account)
    #expect(throws: (any Error).self) {
      try ledger.rejectConnectionLimit("request", turn: "thread/turn")
    }
    try ledger.begin("request", turn: "thread/turn")
    #expect(throws: (any Error).self) {
      try ledger.rejectConnectionLimit("request", turn: "thread/other")
    }
    try ledger.rejectConnectionLimit("request", turn: "thread/turn")
    #expect(try ledger.bound("thread/turn") == account)
    #expect(throws: (any Error).self) { try ledger.bind("thread/turn", account: UUID()) }
    try ledger.begin("request", turn: "thread/turn")
    #expect(throws: (any Error).self) {
      try ledger.begin("request", turn: "thread/turn")
    }
    #expect(throws: (any Error).self) {
      try ledger.rejectConnectionLimit("request", turn: "thread/turn")
    }
    try ledger.finish("request", turn: "thread/turn")
    #expect(throws: (any Error).self) {
      try ledger.begin("request", turn: "thread/turn")
    }
  }

  @Test
  func restartRetainsConfirmedRejectionButBlocksAnUncertainRetry() throws {
    let root = try RouterTestDirectory()
    let account = UUID()
    do {
      let ledger = try RouterLedger(root: root.url)
      try ledger.bind("thread/turn", account: account)
      try ledger.begin("request", turn: "thread/turn")
      try ledger.rejectConnectionLimit("request", turn: "thread/turn")
    }
    do {
      let ledger = try RouterLedger(root: root.url)
      #expect(try ledger.bound("thread/turn") == account)
      try ledger.begin("request", turn: "thread/turn")
    }
    let ledger = try RouterLedger(root: root.url)
    #expect(throws: (any Error).self) { try ledger.bound("thread/turn") }
    #expect(throws: (any Error).self) { try ledger.begin("request", turn: "thread/turn") }
  }
}
