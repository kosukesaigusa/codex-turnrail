import Foundation
import Testing

@testable import CodexTurnrailCore

/// The real Engine must reconnect after an explicit rejection without re-running tools.
enum OfficialEngineConnectionLimitFixture {
  static func verify(
    rpc: OfficialEngineRPC, backend: FixtureModel, provider: FixtureAccounts, root: URL
  ) throws {
    let marker = root.appending(path: "connection-limit-tool.txt")
    let command: [String: Any] = [
      "cmd": "printf 'executed\\n' >> " + RouterJSON.shellQuote(marker.path)
        + "; printf CONNECTION_LIMIT_TOOL_RESULT",
      "login": false, "yield_time_ms": 10000,
    ]
    backend.setTool("text(await tools.exec_command(" + (try RouterJSON.string(command)) + "));")
    let created = try rpc.request(
      "thread/start",
      [
        "cwd": root.path, "ephemeral": true, "approvalPolicy": "never",
        "sandbox": "workspace-write",
      ])
    let thread = try RouterJSON.text(RouterJSON.map(created, "thread"), "id")
    let event: [String: Any] = [
      "type": "error", "status": 400,
      "error": [
        "type": "invalid_request_error", "code": "websocket_connection_limit_reached",
        "message": "PRIVATE_SERVER_MESSAGE", "account_id": "PRIVATE_ACCOUNT",
      ],
    ]
    provider.choose(provider.first.account.id)
    backend.reject(event, after: 1, count: 1, afterCreated: false) {
      // Changing folder priority while reconnecting must not rebind this turn.
      provider.choose(provider.second.account.id)
    }
    let opened = backend.openedAccounts.count
    _ = try rpc.request(
      "turn/start",
      [
        "threadId": thread,
        "input": [["type": "text", "text": "Run the marker exactly once.", "text_elements": []]],
      ])
    let result = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
    let details = try RouterJSON.string(result)
    try #require(result["status"] as? String == "completed", "\(details)")
    let calls = backend.requests(for: try RouterJSON.text(result, "id"))
    try #require(calls.count == 3)
    #expect(calls.allSatisfy { $0.account == provider.first.account.id })
    #expect(backend.openedAccounts.count == opened + 2)
    #expect(calls[1].body.value["previous_response_id"] != nil)
    #expect(calls[2].body.value["previous_response_id"] == nil)
    let restored = try RouterJSON.array(calls[2].body.value, "input")
    let outputs = restored.filter { $0["type"] as? String == "custom_tool_call_output" }
    #expect(outputs.count == 1)
    #expect(try RouterJSON.string(outputs).contains("CONNECTION_LIMIT_TOOL_RESULT"))
    #expect(try String(contentsOf: marker, encoding: .utf8) == "executed\n")
    #expect(try !RouterJSON.string(result).contains("PRIVATE_"))

    // Manual compaction retains the completed turn's account despite the new priority.
    backend.rejectNext(event)
    _ = try rpc.request("thread/compact/start", ["threadId": thread])
    let compact = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
    let compactDetails = try RouterJSON.string(compact)
    try #require(compact["status"] as? String == "completed", "\(compactDetails)")
    let compactCalls = backend.requests(for: try RouterJSON.text(compact, "id"))
    #expect(compactCalls.count == 2)
    #expect(compactCalls.allSatisfy { $0.account == provider.first.account.id })
    #expect(compactCalls.last?.body.value["previous_response_id"] == nil)

    for (count, afterCreated, expectedRequests) in [(2, false, 2), (1, true, 1)] {
      provider.choose(provider.first.account.id)
      backend.reject(event, after: 0, count: count, afterCreated: afterCreated) {
        provider.choose(provider.second.account.id)
      }
      _ = try rpc.request(
        "turn/start",
        [
          "threadId": thread,
          "input": [["type": "text", "text": "Stop unsafe recovery.", "text_elements": []]],
        ])
      let stopped = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
      #expect(stopped["status"] as? String == "failed")
      let stoppedCalls = backend.requests(for: try RouterJSON.text(stopped, "id"))
      #expect(stoppedCalls.count == expectedRequests)
      #expect(stoppedCalls.allSatisfy { $0.account == provider.first.account.id })
      #expect(try !RouterJSON.string(stopped).contains("PRIVATE_"))
    }

    // Neither the successful recovery nor terminal cases disable WebSockets for later turns.
    backend.setTool("text(6 * 7);")
    _ = try rpc.request(
      "turn/start",
      [
        "threadId": thread,
        "input": [["type": "text", "text": "Continue on a new turn.", "text_elements": []]],
      ])
    let continued = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
    #expect(continued["status"] as? String == "completed")
    let continuedCalls = backend.requests(for: try RouterJSON.text(continued, "id"))
    #expect(continuedCalls.count == 2)
    #expect(continuedCalls.allSatisfy { $0.account == provider.second.account.id })
  }
}
