import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterRoutingTests {
  @Test
  func deepestFolderRuleDoesNotMatchSiblingPrefixesOrEscapeAnEmptyRule() throws {
    let root = try RouterTestDirectory()
    let work = root.url.appending(path: "work/project")
    let sibling = root.url.appending(path: "work-other")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    let first = UUID()
    let second = UUID()
    let config = AccountRoutingConfiguration(
      defaultAccountIDs: [first],
      directoryRules: [
        DirectoryAccountRule(
          id: UUID(), directory: root.url.appending(path: "work").path, accountIDs: [second]),
        DirectoryAccountRule(id: UUID(), directory: work.path, accountIDs: []),
      ])
    #expect(try RouterDirectory.accounts(cwd: work.path, routing: config).isEmpty)
    #expect(try RouterDirectory.accounts(cwd: sibling.path, routing: config) == [first])
    #expect(throws: (any Error).self) {
      try RouterDirectory.accounts(cwd: "relative", routing: config)
    }
  }

  @Test
  func linkedWorktreeUsesOriginalFolderAndRejectsAnInvalidBackReference() throws {
    let root = try RouterTestDirectory()
    let original = root.url.appending(path: "work/project")
    let checkout = root.url.appending(path: "managed/task")
    let admin = original.appending(path: ".git/worktrees/task")
    try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: checkout.appending(path: "nested"), withIntermediateDirectories: true)
    try "gitdir: \(admin.path)\n".write(
      to: checkout.appending(path: ".git"), atomically: true, encoding: .utf8)
    try "../..\n".write(to: admin.appending(path: "commondir"), atomically: true, encoding: .utf8)
    try "\(checkout.path)/.git\n".write(
      to: admin.appending(path: "gitdir"), atomically: true, encoding: .utf8)
    let account = UUID()
    let config = AccountRoutingConfiguration(
      defaultAccountIDs: [],
      directoryRules: [
        DirectoryAccountRule(id: UUID(), directory: original.path, accountIDs: [account])
      ])
    #expect(
      try RouterDirectory.accounts(cwd: checkout.appending(path: "nested").path, routing: config)
        == [account])
    try "/another/checkout/.git\n".write(
      to: admin.appending(path: "gitdir"), atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) {
      try RouterDirectory.accounts(cwd: checkout.path, routing: config)
    }
  }

  @Test
  func spendCapCannotHideAvailableGeneralQuota() throws {
    let usage: [String: Any] = [
      "rate_limit": [
        "allowed": true, "limit_reached": false,
        "primary_window": ["used_percent": 0],
      ], "credits": ["has_credits": false], "spend_limit": ["limit_reached": true],
    ]
    #expect(try RouterAccounts.generalQuotaIsUsable(usage))
    #expect(
      try !RouterAccounts.generalQuotaIsUsable([
        "rate_limit": [
          "allowed": true, "limit_reached": false, "secondary_window": ["used_percent": 100],
        ]
      ]))
    #expect(
      try !RouterAccounts.generalQuotaIsUsable([
        "rate_limit": ["allowed": false, "limit_reached": true]
      ]))
    #expect(throws: (any Error).self) { try RouterAccounts.generalQuotaIsUsable([:]) }
    #expect(throws: (any Error).self) {
      try RouterAccounts.generalQuotaIsUsable([
        "rate_limit": [
          "allowed": true, "limit_reached": false, "primary_window": ["used_percent": -1],
        ]
      ])
    }
  }

  @Test
  func accountBindingSurvivesRestartAndRefusesUncertainReplay() throws {
    let root = try RouterTestDirectory()
    let account = UUID()
    do {
      let ledger = try RouterLedger(root: root.url)
      try ledger.bind("thread/turn", account: account)
      try ledger.begin("request-fingerprint", turn: "thread/turn")
      #expect(throws: (any Error).self) { try ledger.bind("thread/turn", account: UUID()) }
      #expect(throws: (any Error).self) {
        try ledger.begin("request-fingerprint", turn: "thread/turn")
      }
    }
    let recovered = try RouterLedger(root: root.url)
    #expect(throws: (any Error).self) { try recovered.bound("thread/turn") }
    try recovered.bind("thread/new-turn", account: account)
    #expect(try recovered.bound("thread/new-turn") == account)
  }

  @Test
  func compactionUsesCompletedTurnWhileTitlesRequireRegistration() throws {
    let root = try RouterTestDirectory()
    let ledger = try RouterLedger(root: root.url)
    let account = UUID()
    try ledger.bind("conversation/turn", account: account)
    try ledger.stop("conversation", turn: "turn")
    #expect(try ledger.completedAccount("conversation") == account)
    let metadata: [String: Any] = [
      "thread_id": "title", "turn_id": "title-turn", "thread_source": "thread_title",
      "turn_trigger": "thread_title", "request_kind": "turn",
    ]
    #expect(throws: (any Error).self) { try RouterRequest.binding(metadata, ledger: ledger) }
    try ledger.registerTitle(thread: "title", cwd: root.url.path, account: account)
    #expect(try RouterRequest.binding(metadata, ledger: ledger).1 == account)
    var invalid = metadata
    invalid["turn_trigger"] = "user"
    #expect(throws: (any Error).self) { try RouterRequest.binding(invalid, ledger: ledger) }
  }

  @Test
  func ordinaryTurnAllowsOmittedOptionalMetadataButStillRequiresItsHookBinding() throws {
    let root = try RouterTestDirectory()
    let ledger = try RouterLedger(root: root.url)
    var metadata: [String: Any] = ["thread_id": "thread", "turn_id": "turn"]
    #expect(throws: (any Error).self) { try RouterRequest.binding(metadata, ledger: ledger) }
    let account = UUID()
    try ledger.bind("thread/turn", account: account)
    #expect(try RouterRequest.binding(metadata, ledger: ledger).1 == account)
    metadata["thread_source"] = 42
    #expect(throws: (any Error).self) { try RouterRequest.binding(metadata, ledger: ledger) }
  }

  @Test
  func goalContinuationInheritsItsCompletedThreadBindingAcrossRestart() throws {
    let root = try RouterTestDirectory()
    let account = UUID()
    let other = UUID()
    do {
      let ledger = try RouterLedger(root: root.url)
      try ledger.bind("conversation/finished", account: account)
      try ledger.stop("conversation", turn: "finished")
      try ledger.bind("conversation/uncompleted", account: other)
      try ledger.bind("other/finished", account: other)
      try ledger.stop("other", turn: "finished")
    }
    let ledger = try RouterLedger(root: root.url)
    let metadata: [String: Any] = [
      "thread_id": "conversation", "turn_id": "goal", "turn_trigger": "goal",
      "request_kind": "turn",
    ]
    #expect(try RouterRequest.binding(metadata, ledger: ledger).1 == account)
    #expect(try ledger.bound("conversation/goal") == account)
    // A bound continuation stays immutable even if another turn later completes.
    try ledger.stop("conversation", turn: "uncompleted")
    #expect(try RouterRequest.binding(metadata, ledger: ledger).1 == account)
    try ledger.stop("conversation", turn: "goal")
    var next = metadata
    next["turn_id"] = "next-goal"
    #expect(try RouterRequest.binding(next, ledger: ledger).1 == account)
    try ledger.fail("conversation/next-goal")
    #expect(throws: (any Error).self) { try RouterRequest.binding(next, ledger: ledger) }
  }

  @Test
  func goalContinuationRequiresACompletedBindingInTheSameThread() throws {
    let root = try RouterTestDirectory()
    let ledger = try RouterLedger(root: root.url)
    let account = UUID()
    try ledger.bind("other/finished", account: account)
    try ledger.stop("other", turn: "finished")
    try ledger.bind("conversation/active", account: account)
    let metadata: [String: Any] = [
      "thread_id": "conversation", "turn_id": "goal", "turn_trigger": "goal",
      "request_kind": "turn",
    ]
    #expect(throws: (any Error).self) { try RouterRequest.binding(metadata, ledger: ledger) }
    #expect(try ledger.bound("conversation/goal") == nil)
  }

  @Test
  func compactionInsideAGoalTurnKeepsItsHookBinding() throws {
    let root = try RouterTestDirectory()
    let runtime = try RouterRuntime(
      root: root.url, accounts: UnselectableAccounts(root: root.url),
      connect: { _, _ in fatalError("This binding-only test cannot contact a model.") })
    defer { runtime.stop() }
    let account = UUID()
    try runtime.ledger.bind("conversation/finished", account: account)
    try runtime.ledger.stop("conversation", turn: "finished")
    _ = try runtime.hook([
      "hook_event_name": "PreCompact", "session_id": "conversation", "turn_id": "goal",
    ])
    let metadata: [String: Any] = [
      "thread_id": "conversation", "turn_id": "goal", "turn_trigger": "goal",
      "request_kind": "compaction",
    ]
    #expect(try RouterRequest.binding(metadata, ledger: runtime.ledger).1 == account)
  }

  @Test
  func automaticBindingDoesNotBypassOtherRoutingRequirements() throws {
    let root = try RouterTestDirectory()
    let ledger = try RouterLedger(root: root.url)
    let account = UUID()
    try ledger.bind("conversation/finished", account: account)
    try ledger.stop("conversation", turn: "finished")
    let metadata: [String: Any] = [
      "thread_id": "conversation", "turn_id": "unbound", "turn_trigger": "goal",
      "request_kind": "turn",
    ]
    for kind in ["prewarm", "compaction"] {
      var invalid = metadata
      invalid["request_kind"] = kind
      #expect(throws: (any Error).self) { try RouterRequest.binding(invalid, ledger: ledger) }
    }
    for trigger in ["composer", "memory_consolidation", "retry"] {
      var invalid = metadata
      invalid["turn_trigger"] = trigger
      #expect(throws: (any Error).self) { try RouterRequest.binding(invalid, ledger: ledger) }
    }
    for source in ["thread_title", "subagent", "guardian_review"] {
      var invalid = metadata
      invalid["thread_source"] = source
      #expect(throws: (any Error).self) { try RouterRequest.binding(invalid, ledger: ledger) }
    }
    #expect(try ledger.bound("conversation/unbound") == nil)
  }

  @Test
  func childTurnInheritsExactParentTurnInsteadOfCurrentFolderPriority() throws {
    let root = try RouterTestDirectory()
    let ledger = try RouterLedger(root: root.url)
    let account = UUID()
    try ledger.bind("parent/original", account: account)
    try ledger.bind("parent/next", account: UUID())
    let metadata: [String: Any] = [
      "thread_id": "child", "turn_id": "child-turn", "thread_source": "subagent",
      "turn_trigger": "subagent", "parent_thread_id": "parent", "parent_turn_id": "original",
    ]
    #expect(try RouterRequest.binding(metadata, ledger: ledger).1 == account)
    var invalid = metadata
    invalid.removeValue(forKey: "parent_turn_id")
    #expect(throws: (any Error).self) { try RouterRequest.binding(invalid, ledger: ledger) }
  }

  @Test
  func childPromptHookWaitsForParentMetadataWithoutSelectingAnotherAccount() throws {
    let root = try RouterTestDirectory()
    let runtime = try RouterRuntime(
      root: root.url, accounts: UnselectableAccounts(root: root.url),
      connect: { _, _ in fatalError("This hook-only test cannot contact a model.") })
    defer { runtime.stop() }
    let parentAccount = UUID()
    try runtime.ledger.bind("parent/turn", account: parentAccount)
    let decision = try runtime.hook([
      "hook_event_name": "UserPromptSubmit", "session_id": "child",
      "turn_id": "child-turn", "agent_id": "child-agent", "cwd": root.url.path,
    ])
    #expect(decision["continue"] as? Bool == true)
    #expect(try runtime.ledger.bound("child/child-turn") == nil)
    #expect(
      try RouterRequest.binding(
        [
          "thread_id": "child", "turn_id": "child-turn", "thread_source": "subagent",
          "turn_trigger": "subagent", "parent_thread_id": "parent", "parent_turn_id": "turn",
        ], ledger: runtime.ledger
      ).1 == parentAccount)
  }

  @Test
  func accountChangesReconstructOnlyKnownHistory() throws {
    let root = try RouterTestDirectory()
    let ledger = try RouterLedger(root: root.url)
    let first = UUID()
    let second = UUID()
    let history: [String: Any] = [
      "thread": "thread", "input": [["type": "message", "content": "original"]],
      "output": [["type": "message", "content": "answer"]],
      "account": first.uuidString.lowercased(), "generation": "connection-1",
    ]
    try ledger.saveHistory(id: "response-1", value: history)
    let request: [String: Any] = [
      "type": "response.create", "previous_response_id": "response-1",
      "input": [["type": "message", "content": "follow-up"]],
    ]
    let (input, previous) = try RouterRequest.expanded(request, thread: "thread", ledger: ledger)
    #expect(input.count == 3)
    let native = RouterRequest.payload(
      request, input: input, previous: previous, account: first, generation: "connection-1")
    #expect(native["previous_response_id"] as? String == "response-1")
    let switched = RouterRequest.payload(
      request, input: input, previous: previous, account: second, generation: "connection-2")
    #expect(switched["previous_response_id"] == nil)
    #expect((switched["input"] as? [[String: Any]])?.count == 3)
    #expect(throws: (any Error).self) {
      try RouterRequest.expanded(request, thread: "unrelated", ledger: ledger)
    }
  }

  @Test
  func observerAcceptsDesktopGlobalOptionsAndRegistersBeforeReply() throws {
    #expect(
      try RouterEngineObserver.isAppServer([
        "-c", "features.code_mode_host=true", "app-server", "--analytics-default-enabled", "-c",
        "plugins.example.enabled=true",
      ]))
    #expect(try !RouterEngineObserver.isAppServer(["--version"]))
    #expect(throws: (any Error).self) {
      try RouterEngineObserver.isAppServer(["exec", "a prompt"])
    }
    #expect(throws: (any Error).self) {
      try RouterEngineObserver.isAppServer(["app-server", "--listen=ws://127.0.0.1"])
    }
    let observer = RouterEngineObserver()
    try observer.request([
      "id": 1, "method": "thread/start", "params": ["threadSource": "thread_title"],
    ])
    var registered = false
    try observer.response(["id": 1, "method": "approval/request"]) { _ in
      Issue.record("Server requests cannot consume client request IDs")
    }
    try observer.response(["id": 1, "result": ["thread": ["id": "title", "cwd": "/work"]]]) {
      value in
      #expect(value["id"] as? String == "title")
      registered = true
    }
    #expect(registered)
    #expect(throws: (any Error).self) {
      try observer.request([
        "id": 2, "method": "thread/start",
        "params": ["config": ["openai_base_url": "https://unbound.invalid"]],
      ])
    }
  }
}

private struct UnselectableAccounts: RouterAccountProviding {
  let root: URL
  func select(cwd: String) throws -> RouterAccountSnapshot {
    throw RouterFailure("A child hook must not select an account from its folder.")
  }
  func bound(_ id: UUID) throws -> RouterAccountSnapshot {
    throw RouterFailure("This hook test does not load credentials.")
  }
  func commonCatalog() throws -> [String: Any] {
    throw RouterFailure("This hook test does not load models.")
  }
}

final class RouterTestDirectory {
  let url: URL
  init() throws {
    url = FileManager.default.temporaryDirectory.appending(
      path: "turnrail-unit-\(UUID().uuidString)"
    ).resolvingSymlinksInPath()
    try RouterJSON.privateDirectory(url)
  }
  deinit { try? FileManager.default.removeItem(at: url) }
}
