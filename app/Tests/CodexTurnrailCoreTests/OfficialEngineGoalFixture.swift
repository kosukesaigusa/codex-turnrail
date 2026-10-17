import Foundation
import Testing

@testable import CodexTurnrailCore

/// Goal continuations bypass prompt hooks and must retain their completed thread's account.
enum OfficialEngineGoalFixture {
  static func verify(
    rpc: OfficialEngineRPC, backend: FixtureModel, provider: FixtureAccounts, root: URL,
    userHookMarker: URL
  ) throws {
    defer { backend.setTool("text(6 * 7);") }
    backend.setTool("text(6 * 7);")
    provider.choose(provider.first.account.id)
    let created = try rpc.request(
      "thread/start", ["cwd": root.path, "ephemeral": false])
    let thread = try RouterJSON.text(RouterJSON.map(created, "thread"), "id")
    _ = try rpc.request(
      "turn/start",
      [
        "threadId": thread,
        "input": [["type": "text", "text": "Seed the Goal routing check.", "text_elements": []]],
      ])
    let seed = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
    try #require(seed["status"] as? String == "completed")
    let seedCalls = backend.requests(for: try RouterJSON.text(seed, "id"))
    try #require(seedCalls.count == 2)
    #expect(seedCalls.allSatisfy { $0.account == provider.first.account.id })

    let beforeGoalHooks = try Data(contentsOf: userHookMarker)
    provider.choose(provider.second.account.id)
    for status in ["paused", "complete"] {
      backend.setTool("text(await tools.update_goal({status: \"\(status)\"}));")
      var params: [String: Any] = ["threadId": thread, "status": "active"]
      if status == "paused" {
        params["objective"] = "Exercise an isolated Goal continuation, pause it, then resume it."
      }
      _ = try rpc.request("thread/goal/set", params)
      let continued = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
      let details = try RouterJSON.string(continued)
      try #require(continued["status"] as? String == "completed", "\(details)")
      #expect(continued["id"] as? String != seed["id"] as? String)
      let calls = backend.requests(for: try RouterJSON.text(continued, "id"))
      try #require(calls.count == 2)
      #expect(calls.allSatisfy { $0.account == provider.first.account.id })
      #expect(
        try calls.allSatisfy {
          try RouterRequest.metadata($0.body.value)["turn_trigger"] as? String == "goal"
        })
      let outputs = try calls.flatMap { try RouterJSON.array($0.body.value, "input") }.filter {
        $0["type"] as? String == "custom_tool_call_output"
      }
      #expect(try RouterJSON.string(outputs).contains(status))
      let goal = try RouterJSON.map(
        rpc.request("thread/goal/get", ["threadId": thread]), "goal")
      #expect(goal["status"] as? String == status)
      #expect(try Data(contentsOf: userHookMarker) == beforeGoalHooks)
    }

    // A new user turn still follows the new folder priority and runs its prompt hook.
    backend.setTool("text(6 * 7);")
    _ = try rpc.request(
      "turn/start",
      [
        "threadId": thread,
        "input": [["type": "text", "text": "Continue with a user turn.", "text_elements": []]],
      ])
    let userTurn = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
    try #require(userTurn["status"] as? String == "completed")
    let userCalls = backend.requests(for: try RouterJSON.text(userTurn, "id"))
    #expect(userCalls.count == 2)
    #expect(userCalls.allSatisfy { $0.account == provider.second.account.id })
    #expect(
      try Data(contentsOf: userHookMarker) == beforeGoalHooks + Data("invoked\n".utf8))
  }
}
