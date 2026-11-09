import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterResumeTests {
  @Test
  func resumedTurnUsesItsAdmittedFolderSelectionAndKeepsIt() throws {
    let root = try RouterTestDirectory()
    let accounts = try FixtureAccounts(root: root.url)
    let runtime = try makeRuntime(root.url, accounts)
    defer { runtime.stop() }
    try load(runtime, thread: "thread", cwd: root.url.path)

    // The interrupted turn can have no Turnrail history at all.
    accounts.choose(accounts.second.account.id)
    try admit(runtime, id: "resume", thread: "thread")
    try acknowledge(runtime, id: "resume", turn: "resumed")
    let metadata = request(thread: "thread", turn: "resumed")
    try runtime.bindResumedTurn(metadata)
    accounts.choose(accounts.first.account.id)
    #expect(
      try RouterRequest.binding(metadata, ledger: runtime.ledger).1 == accounts.second.account.id)
    try runtime.bindResumedTurn(metadata)
    #expect(try runtime.ledger.bound("thread/resumed") == accounts.second.account.id)
  }

  @Test
  func responseBeforeModelRequestStillBindsOnlyTheConfirmedTurn() throws {
    let root = try RouterTestDirectory()
    let accounts = try FixtureAccounts(root: root.url)
    let runtime = try makeRuntime(root.url, accounts)
    defer { runtime.stop() }
    try load(runtime, thread: "thread", cwd: root.url.path)
    try admit(runtime, id: "resume", thread: "thread")
    try acknowledge(runtime, id: "resume", turn: "correct")
    #expect(throws: (any Error).self) {
      try runtime.bindResumedTurn(request(thread: "thread", turn: "wrong"))
    }
    #expect(throws: (any Error).self) {
      try runtime.bindResumedTurn(request(thread: "other", turn: "correct"))
    }
    try runtime.bindResumedTurn(request(thread: "thread", turn: "correct"))
    #expect(try runtime.ledger.bound("thread/correct") == accounts.first.account.id)
  }

  @Test
  func compactionBeforeFirstInferenceUsesTheConfirmedResumedTurn() throws {
    let root = try RouterTestDirectory()
    let accounts = try FixtureAccounts(root: root.url)
    let runtime = try makeRuntime(root.url, accounts)
    defer { runtime.stop() }
    try load(runtime, thread: "thread", cwd: root.url.path)
    try admit(runtime, id: "resume", thread: "thread")
    try acknowledge(runtime, id: "resume", turn: "resumed")
    _ = try runtime.hook([
      "hook_event_name": "PreCompact", "session_id": "thread", "turn_id": "resumed",
    ])
    #expect(try runtime.ledger.bound("thread/resumed") == accounts.first.account.id)
    try runtime.bindResumedTurn(request(thread: "thread", turn: "resumed"))
  }

  @Test
  func compactionWaitsForTheEngineToIdentifyTheAdmittedTurn() throws {
    let root = try RouterTestDirectory()
    let accounts = try FixtureAccounts(root: root.url)
    let runtime = try makeRuntime(root.url, accounts)
    defer { runtime.stop() }
    try load(runtime, thread: "thread", cwd: root.url.path)
    try admit(runtime, id: "resume", thread: "thread")
    let started = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let output = ResumeResult()
    let worker = Thread {
      started.signal()
      do {
        _ = try runtime.hook([
          "hook_event_name": "PreCompact", "session_id": "thread", "turn_id": "resumed",
        ])
        output.complete(nil)
      } catch { output.complete(error) }
      done.signal()
    }
    worker.start()
    try #require(started.wait(timeout: .now() + 30) == .success)
    try acknowledge(runtime, id: "resume", turn: "resumed")
    try #require(done.wait(timeout: .now() + 30) == .success)
    #expect(output.error == nil)
    #expect(try runtime.ledger.bound("thread/resumed") == accounts.first.account.id)
  }

  @Test
  func explicitResumeDirectoryAndUnrelatedThreadResponsesAreHandledSeparately() throws {
    let root = try RouterTestDirectory()
    let tracker = RouterResumeTracker()
    try tracker.request(["id": "load", "method": "thread/resume", "params": [:]])
    // An unrelated or malformed load response must not break the original RPC.
    try tracker.response(["id": "load", "result": ["thread": ["id": "thread"]]])
    tracker.remember(thread: "thread", cwd: "/missing-directory")
    try tracker.request([
      "id": "resume", "method": "turn/start",
      "params": [
        "threadId": "thread", "turnTrigger": "resume_interrupted_task", "input": [Any](),
        "cwd": root.url.path,
      ],
    ])
    try tracker.response(["id": "resume", "result": ["turn": ["id": "resumed"]]])
    #expect(
      try tracker.claim(thread: "thread", turn: "resumed") == root.url.path)
  }

  @Test
  func rejectedOrUnadmittedResumesCannotSelectAnAccount() throws {
    let root = try RouterTestDirectory()
    let accounts = try FixtureAccounts(root: root.url)
    let runtime = try makeRuntime(root.url, accounts)
    defer { runtime.stop() }
    #expect(throws: (any Error).self) {
      try admit(runtime, id: "missing", thread: "thread")
    }
    try load(runtime, thread: "thread", cwd: root.url.path)
    try admit(runtime, id: "rejected", thread: "thread")
    try runtime.observeResponse(["id": "rejected", "error": ["code": -1]])
    #expect(throws: (any Error).self) {
      try runtime.bindResumedTurn(request(thread: "thread", turn: "resumed"))
    }
    #expect(try runtime.ledger.bound("thread/resumed") == nil)
    try admit(runtime, id: "next", thread: "thread")
    #expect(throws: (any Error).self) {
      try admit(runtime, id: "duplicate", thread: "thread")
    }
  }

  @Test
  func aTurnThatEndsBeforeItsStartResponseDoesNotBlockAnotherResume() throws {
    let root = try RouterTestDirectory()
    let accounts = try FixtureAccounts(root: root.url)
    let runtime = try makeRuntime(root.url, accounts)
    defer { runtime.stop() }
    try load(runtime, thread: "thread", cwd: root.url.path)
    try admit(runtime, id: "first", thread: "thread")
    try runtime.observeResponse([
      "method": "turn/completed", "params": ["threadId": "thread", "turn": ["id": "resumed"]],
    ])
    try acknowledge(runtime, id: "first", turn: "resumed")
    #expect(throws: (any Error).self) {
      try runtime.bindResumedTurn(request(thread: "thread", turn: "resumed"))
    }
    try admit(runtime, id: "second", thread: "thread")
  }

  @Test
  func resumeMustNotOverrideTheRoutingOfOtherRequests() throws {
    let root = try RouterTestDirectory()
    let accounts = try FixtureAccounts(root: root.url)
    let runtime = try makeRuntime(root.url, accounts)
    defer { runtime.stop() }
    try load(runtime, thread: "thread", cwd: root.url.path)
    try admit(runtime, id: "resume", thread: "thread")
    for source in ["subagent", "guardian_review", "thread_title"] {
      var metadata = request(thread: "thread", turn: "turn")
      metadata["thread_source"] = source
      try runtime.bindResumedTurn(metadata)
      #expect(try runtime.ledger.bound("thread/turn") == nil)
    }
    var other = request(thread: "thread", turn: "turn")
    other["turn_trigger"] = "composer"
    try runtime.bindResumedTurn(other)
    #expect(try runtime.ledger.bound("thread/turn") == nil)
    other = request(thread: "thread", turn: "turn")
    other["thread_source"] = 42
    #expect(throws: (any Error).self) { try runtime.bindResumedTurn(other) }
    #expect(try runtime.ledger.bound("thread/turn") == nil)
    try runtime.ledger.registerTitle(
      thread: "title", cwd: root.url.path, account: accounts.first.account.id)
    try load(runtime, thread: "title", cwd: root.url.path)
    #expect(throws: (any Error).self) { try admit(runtime, id: "title-resume", thread: "title") }
  }

  @Test
  func toolOutputIsNotAdmittedAsAnEmptyUserResume() throws {
    let root = try RouterTestDirectory()
    let accounts = try FixtureAccounts(root: root.url)
    let runtime = try makeRuntime(root.url, accounts)
    defer { runtime.stop() }
    try load(runtime, thread: "thread", cwd: root.url.path)
    try runtime.observeRequest([
      "id": "tool-output", "method": "turn/start",
      "params": [
        "threadId": "thread", "turnTrigger": "resume_interrupted_task", "input": [Any](),
        "toolOutput": ["name": "example", "output": "result"],
      ],
    ])
    #expect(throws: (any Error).self) {
      try runtime.bindResumedTurn(request(thread: "thread", turn: "turn"))
    }
    #expect(try runtime.ledger.bound("thread/turn") == nil)
  }

  private func makeRuntime(_ root: URL, _ accounts: FixtureAccounts) throws -> RouterRuntime {
    try RouterRuntime(
      root: root, accounts: accounts,
      connect: { _, _ in
        fatalError("This test does not contact a model.")
      })
  }

  private func load(_ runtime: RouterRuntime, thread: String, cwd: String) throws {
    let id = "load-" + thread
    try runtime.observeRequest([
      "id": id, "method": "thread/resume", "params": ["threadId": thread],
    ])
    try runtime.observeResponse(["id": id, "result": ["thread": ["id": thread, "cwd": cwd]]])
  }

  private func admit(_ runtime: RouterRuntime, id: String, thread: String) throws {
    try runtime.observeRequest([
      "id": id, "method": "turn/start",
      "params": [
        "threadId": thread, "turnTrigger": "resume_interrupted_task", "input": [Any](),
      ],
    ])
  }

  private func acknowledge(_ runtime: RouterRuntime, id: String, turn: String) throws {
    try runtime.observeResponse(["id": id, "result": ["turn": ["id": turn]]])
  }

  private func request(thread: String, turn: String) -> [String: Any] {
    [
      "thread_id": thread, "turn_id": turn, "turn_trigger": "resume_interrupted_task",
      "request_kind": "turn",
    ]
  }
}

private final class ResumeResult: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Error?
  var error: Error? { lock.withLock { stored } }
  func complete(_ error: Error?) { lock.withLock { stored = error } }
}
