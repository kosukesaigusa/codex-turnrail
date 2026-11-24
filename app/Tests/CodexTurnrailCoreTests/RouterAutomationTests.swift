import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterAutomationTests {
  private let triggers: [RouterAdmittedTurnTrigger] = [
    .scheduledHeartbeat, .immediateHeartbeat, .scheduledAutomation, .immediateAutomation,
  ]

  @Test
  func automationBindsTheConfirmedTurnToTheCurrentFolderSelection() throws {
    for trigger in triggers {
      let root = try RouterTestDirectory()
      let accounts = try FixtureAccounts(root: root.url)
      let runtime = try makeRuntime(root.url, accounts)
      defer { runtime.stop() }
      try load(runtime, cwd: root.url.path)
      accounts.choose(accounts.second.account.id)
      try admit(runtime, trigger: trigger)
      try acknowledge(runtime, turn: "scheduled")
      let metadata = request(trigger: trigger, turn: "scheduled")
      try runtime.bindAdmittedTurn(metadata)
      accounts.choose(accounts.first.account.id)
      #expect(
        try RouterRequest.binding(metadata, ledger: runtime.ledger).1 == accounts.second.account.id)
      try runtime.bindAdmittedTurn(metadata)
      #expect(accounts.selections == 1)
    }
  }

  @Test
  func automationRequiresTheExactDesktopRequestAndConfirmedTurn() throws {
    let root = try RouterTestDirectory()
    let accounts = try FixtureAccounts(root: root.url)
    let runtime = try makeRuntime(root.url, accounts)
    defer { runtime.stop() }
    try load(runtime, cwd: root.url.path)
    let trigger = RouterAdmittedTurnTrigger.scheduledHeartbeat
    let outputs: [Any] = [
      NSNull(),
      ["name": "other", "namespace": "codex_app", "output": "x"],
      ["name": "automation_update", "namespace": "other", "output": "x"],
    ]
    for output in outputs {
      try runtime.observeRequest([
        "id": "unrelated", "method": "turn/start",
        "params": [
          "threadId": "thread", "turnTrigger": trigger.rawValue, "input": [Any](),
          "toolOutput": output,
        ],
      ])
      try runtime.observeResponse(["id": "unrelated", "result": ["turn": ["id": "turn"]]])
      #expect(throws: (any Error).self) {
        try runtime.bindAdmittedTurn(request(trigger: trigger, turn: "turn"))
      }
    }
    try admit(runtime, trigger: trigger)
    try acknowledge(runtime, turn: "confirmed")
    #expect(throws: (any Error).self) {
      try runtime.bindAdmittedTurn(request(trigger: trigger, turn: "other"))
    }
    #expect(throws: (any Error).self) {
      try runtime.bindAdmittedTurn(request(trigger: .scheduledAutomation, turn: "confirmed"))
    }
    #expect(try runtime.ledger.bound("thread/confirmed") == nil)
    try runtime.bindAdmittedTurn(request(trigger: trigger, turn: "confirmed"))
    #expect(try runtime.ledger.bound("thread/confirmed") == accounts.first.account.id)
    #expect(accounts.selections == 1)
  }

  @Test
  func automationUsesTheExplicitTurnDirectory() throws {
    let root = try RouterTestDirectory()
    let accounts = try FixtureAccounts(root: root.url)
    let runtime = try makeRuntime(root.url, accounts)
    defer { runtime.stop() }
    let previous = root.url.appending(path: "previous")
    try RouterJSON.privateDirectory(previous)
    try load(runtime, cwd: previous.path)
    try runtime.observeRequest([
      "id": "automation", "method": "turn/start",
      "params": [
        "threadId": "thread", "turnTrigger": "automation_heartbeat_scheduled",
        "input": [Any](), "cwd": root.url.path,
        "toolOutput": ["name": "automation_update", "namespace": "codex_app", "output": "Run"],
      ],
    ])
    try acknowledge(runtime, turn: "turn")
    try runtime.bindAdmittedTurn(request(trigger: .scheduledHeartbeat, turn: "turn"))
    #expect(try runtime.ledger.bound("thread/turn") == accounts.first.account.id)
  }

  @Test
  func automationWithTextInputUsesThePromptHook() throws {
    let root = try RouterTestDirectory()
    let accounts = try FixtureAccounts(root: root.url)
    let runtime = try makeRuntime(root.url, accounts)
    defer { runtime.stop() }
    try load(runtime, cwd: root.url.path)
    try runtime.observeRequest([
      "id": "text", "method": "turn/start",
      "params": [
        "threadId": "thread", "turnTrigger": "automation_heartbeat_scheduled",
        "input": [["type": "text", "text": "Scheduled input"]],
      ],
    ])
    try runtime.observeResponse(["id": "text", "result": ["turn": ["id": "turn"]]])
    let metadata = request(trigger: .scheduledHeartbeat, turn: "turn")
    #expect(throws: (any Error).self) { try runtime.bindAdmittedTurn(metadata) }
    _ = try runtime.hook([
      "hook_event_name": "UserPromptSubmit", "session_id": "thread", "turn_id": "turn",
      "cwd": root.url.path,
    ])
    try runtime.bindAdmittedTurn(metadata)
    #expect(
      try RouterRequest.binding(metadata, ledger: runtime.ledger).1 == accounts.first.account.id)
  }

  @Test
  func automationCompactionUsesTheConfirmedTurnAndRejectedStartsDoNotBind() throws {
    let root = try RouterTestDirectory()
    let accounts = try FixtureAccounts(root: root.url)
    let runtime = try makeRuntime(root.url, accounts)
    defer { runtime.stop() }
    try load(runtime, cwd: root.url.path)
    try admit(runtime, trigger: .scheduledHeartbeat)
    try runtime.observeResponse(["id": "automation", "error": ["code": -1]])
    #expect(throws: (any Error).self) {
      try runtime.bindAdmittedTurn(request(trigger: .scheduledHeartbeat, turn: "rejected"))
    }
    try admit(runtime, trigger: .scheduledHeartbeat)
    try acknowledge(runtime, turn: "compact")
    _ = try runtime.hook([
      "hook_event_name": "PreCompact", "session_id": "thread", "turn_id": "compact",
    ])
    #expect(try runtime.ledger.bound("thread/compact") == accounts.first.account.id)
    try runtime.bindAdmittedTurn(request(trigger: .scheduledHeartbeat, turn: "compact"))
    #expect(accounts.selections == 1)
  }

  @Test
  func automationSteeredIntoAnActiveTurnKeepsItsBindingAndClearsAdmission() throws {
    let root = try RouterTestDirectory()
    let accounts = try FixtureAccounts(root: root.url)
    let runtime = try makeRuntime(root.url, accounts)
    defer { runtime.stop() }
    try load(runtime, cwd: root.url.path)
    try runtime.ledger.bind("thread/active", account: accounts.first.account.id)
    accounts.choose(accounts.second.account.id)
    try admit(runtime, trigger: .scheduledHeartbeat)
    try acknowledge(runtime, turn: "active")
    let active: [String: Any] = [
      "thread_id": "thread", "turn_id": "active", "turn_trigger": "composer",
      "request_kind": "turn",
    ]
    try runtime.bindAdmittedTurn(active)
    #expect(
      try RouterRequest.binding(active, ledger: runtime.ledger).1 == accounts.first.account.id)
    try runtime.observeResponse([
      "method": "turn/completed", "params": ["threadId": "thread", "turn": ["id": "active"]],
    ])
    try admit(runtime, trigger: .scheduledHeartbeat)
    try acknowledge(runtime, turn: "next")
    try runtime.bindAdmittedTurn(request(trigger: .scheduledHeartbeat, turn: "next"))
    #expect(try runtime.ledger.bound("thread/next") == accounts.second.account.id)
  }

  @Test
  func automationChildRetainsItsParentTurnAccount() throws {
    let root = try RouterTestDirectory()
    let accounts = try FixtureAccounts(root: root.url)
    let runtime = try makeRuntime(root.url, accounts)
    defer { runtime.stop() }
    try runtime.ledger.bind("thread/parent", account: accounts.first.account.id)
    accounts.choose(accounts.second.account.id)
    var child = request(trigger: .scheduledHeartbeat, turn: "child-turn")
    child["thread_id"] = "child"
    child["thread_source"] = "subagent"
    child["parent_thread_id"] = "thread"
    child["parent_turn_id"] = "parent"
    try runtime.bindAdmittedTurn(child)
    #expect(try RouterRequest.binding(child, ledger: runtime.ledger).1 == accounts.first.account.id)
    #expect(accounts.selections == 0)
  }

  @Test(.timeLimit(.minutes(1)))
  func automationWaitsForTheEngineToConfirmTheTurn() throws {
    let root = try RouterTestDirectory()
    let accounts = try FixtureAccounts(root: root.url)
    let runtime = try makeRuntime(root.url, accounts)
    defer { runtime.stop() }
    try load(runtime, cwd: root.url.path)
    try admit(runtime, trigger: .scheduledHeartbeat)
    let started = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let result = AutomationResult()
    let worker = Thread {
      started.signal()
      do {
        try runtime.bindAdmittedTurn([
          "thread_id": "thread", "turn_id": "confirmed",
          "turn_trigger": "automation_heartbeat_scheduled", "request_kind": "turn",
        ])
        result.complete(nil)
      } catch { result.complete(error) }
      finished.signal()
    }
    worker.start()
    try #require(started.wait(timeout: .now() + 30) == .success)
    #expect(accounts.selections == 0)
    try acknowledge(runtime, turn: "confirmed")
    try #require(finished.wait(timeout: .now() + 30) == .success)
    #expect(result.error == nil)
    #expect(try runtime.ledger.bound("thread/confirmed") == accounts.first.account.id)
  }

  private func makeRuntime(_ root: URL, _ accounts: FixtureAccounts) throws -> RouterRuntime {
    try RouterRuntime(root: root, accounts: accounts) { _, _ in
      fatalError("This fixture does not contact a model.")
    }
  }

  private func load(_ runtime: RouterRuntime, cwd: String) throws {
    try runtime.observeRequest([
      "id": "load", "method": "thread/resume", "params": ["threadId": "thread"],
    ])
    try runtime.observeResponse([
      "id": "load", "result": ["thread": ["id": "thread", "cwd": cwd]],
    ])
  }

  private func admit(_ runtime: RouterRuntime, trigger: RouterAdmittedTurnTrigger) throws {
    try runtime.observeRequest([
      "id": "automation", "method": "turn/start",
      "params": [
        "threadId": "thread", "turnTrigger": trigger.rawValue, "input": [Any](),
        "toolOutput": ["name": "automation_update", "namespace": "codex_app", "output": "Run"],
      ],
    ])
  }

  private func acknowledge(_ runtime: RouterRuntime, turn: String) throws {
    try runtime.observeResponse(["id": "automation", "result": ["turn": ["id": turn]]])
  }

  private func request(trigger: RouterAdmittedTurnTrigger, turn: String) -> [String: Any] {
    [
      "thread_id": "thread", "turn_id": turn, "turn_trigger": trigger.rawValue,
      "request_kind": "turn",
    ]
  }
}

private final class AutomationResult: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Error?
  var error: Error? { lock.withLock { stored } }
  func complete(_ error: Error?) { lock.withLock { stored = error } }
}
