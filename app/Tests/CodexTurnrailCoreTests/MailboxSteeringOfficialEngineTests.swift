import Foundation
import Testing

@testable import CodexTurnrailCore

/// Script every model response locally; exercise the signed Engine's mailbox preemption.
enum OfficialEngineMailboxFixture {
  static func verify(app: URL, router: URL) throws {
    let installed = try OfficialEngineInstallation.verify(app: app)
    let root = try RouterTestDirectory()
    let accounts = try FixtureAccounts(root: root.url)
    let marker = root.url.appending(path: "mailbox-marker.txt")
    let command: [String: Any] = [
      "cmd": "printf 'executed\\n' >> " + RouterJSON.shellQuote(marker.path)
        + "; printf MAILBOX_TOOL_RESULT",
      "login": false, "yield_time_ms": 10000,
    ]
    let model = MailboxModel(
      tool: "text(await tools.exec_command(" + (try RouterJSON.string(command)) + "));",
      changedPriority: { accounts.choose(accounts.second.account.id) })
    let runtime = try RouterRuntime(
      root: root.url, accounts: accounts,
      connect: { account, _ in MailboxUpstream(account: account.account.id, model: model) })
    runtime.start()
    defer { runtime.stop() }
    let home = root.url.appending(path: "home")
    try RouterJSON.privateDirectory(home)
    let auth = try RouterJSON.data(["OPENAI_API_KEY": "SYNTHETIC_MAILBOX_TEST"])
    let authFile = home.appending(path: "auth.json")
    try RouterJSON.writePrivate(auth, to: authFile)
    let overrides =
      try runtime.configuration(engine: installed.paths.launcher, home: home, executable: router)
      + [
        "cli_auth_credentials_store=\"file\"", "model=\"gpt-5.6-luna\"",
        "model_reasoning_effort=\"low\"", "features.apps=false", "features.plugins=false",
        "features.memories=false", "analytics.enabled=false", "web_search=\"disabled\"",
        "features.code_mode=true", "features.code_mode_host=true", "features.code_mode_only=true",
        "features.multi_agent_v2.enabled=true", "features.multi_agent_v2.non_code_mode_only=true",
        "features.shell_tool=true", "approval_policy=\"never\"", "sandbox_mode=\"workspace-write\"",
      ]
    let rpc = try OfficialEngineRPC(
      engine: installed.paths.launcher, home: home, overrides: overrides, timeoutSeconds: 60)
    defer { rpc.close() }
    let thread = try RouterJSON.text(
      RouterJSON.map(
        rpc.request("thread/start", ["cwd": root.url.path, "ephemeral": true]), "thread"),
      "id")
    let start = try rpc.request(
      "turn/start",
      [
        "threadId": thread,
        "input": [
          ["type": "text", "text": "Run the isolated mailbox check.", "text_elements": []]
        ],
      ])
    let turn = try RouterJSON.text(RouterJSON.map(start, "turn"), "id")
    var done = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
    while try RouterJSON.text(done, "id") != turn {
      done = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
    }
    try #require(done["status"] as? String == "completed", "\(done)")
    let calls = model.requests
    let parent = calls.filter { $0.thread == thread }
    try #require(parent.count == 4)
    #expect(parent.allSatisfy { $0.turn == turn && $0.account == accounts.first.account.id })
    #expect(parent.last?.input.contains("MAILBOX_REPORT") == true)
    #expect(parent.last?.input.contains("MAILBOX_TOOL_RESULT") == true)
    #expect(try String(contentsOf: marker, encoding: .utf8) == "executed\n")
    #expect(try runtime.ledger.bound(thread + "/" + turn) == accounts.first.account.id)
    let child = calls.filter { $0.thread != thread }
    #expect(child.count == 2)
    #expect(child.allSatisfy { $0.account == accounts.first.account.id })
    #expect(try Data(contentsOf: authFile) == auth)
  }
}

private final class MailboxModel: @unchecked Sendable {
  struct Request: Sendable {
    let thread: String
    let turn: String
    let account: UUID
    let input: String
  }
  private let condition = NSCondition()
  private let tool: String
  private let changedPriority: @Sendable () -> Void
  private var calls: [Request] = []
  private var parentWaiting = false
  private var reportSent = false
  var requests: [Request] { condition.withLock { calls } }

  init(tool: String, changedPriority: @escaping @Sendable () -> Void) {
    self.tool = tool
    self.changedPriority = changedPriority
  }

  func response(_ data: Data, account: UUID) throws -> ([Data], Bool) {
    condition.lock()
    defer { condition.unlock() }
    let body = try RouterJSON.object(data)
    let metadata = try RouterRequest.metadata(body)
    let thread = try RouterJSON.text(metadata, "thread_id")
    calls.append(
      Request(
        thread: thread, turn: try RouterJSON.text(metadata, "turn_id"), account: account,
        input: try RouterJSON.string(RouterJSON.array(body, "input"))))
    let number = calls.filter { $0.thread == thread }.count
    let id = "mailbox-\(thread)-\(number)"
    let item: [String: Any]
    if metadata["thread_source"] as? String == "subagent" {
      if number == 1 {
        try wait { parentWaiting }
        item = try Self.function("send_message", ["target": "/root", "message": "MAILBOX_REPORT"])
      } else {
        reportSent = true
        condition.broadcast()
        item = Self.message("Report delivered.")
      }
    } else {
      switch number {
      case 1:
        item = [
          "type": "custom_tool_call", "id": "marker", "call_id": "mailbox-marker",
          "name": "exec", "input": tool,
        ]
      case 2:
        item = try Self.function(
          "spawn_agent",
          [
            "task_name": "fixture_report", "fork_turns": "none",
            "message":
              "Send MAILBOX_REPORT to /root with send_message, then finish. Do nothing else.",
          ])
      case 3:
        parentWaiting = true
        changedPriority()
        condition.broadcast()
        return (
          try [
            ["type": "response.created", "response": ["id": id]],
            [
              "type": "response.output_item.added",
              "item": [
                "type": "message", "role": "assistant", "id": "mailbox-boundary",
                "phase": "commentary",
                "content": [["type": "output_text", "text": "Waiting for the report."]],
              ],
            ],
          ].map(RouterJSON.data), true
        )
      default: item = Self.message("Mailbox continuation completed.")
      }
    }
    return (
      try [
        ["type": "response.created", "response": ["id": id]],
        ["type": "response.output_item.done", "item": item],
        [
          "type": "response.completed",
          "response": [
            "id": id, "usage": ["input_tokens": 1, "output_tokens": 1, "total_tokens": 2],
          ],
        ],
      ].map(RouterJSON.data), false
    )
  }

  func commentaryDone() throws -> Data {
    condition.lock()
    defer { condition.unlock() }
    try wait { reportSent }
    return try RouterJSON.data([
      "type": "response.output_item.done",
      "item": [
        "type": "message", "role": "assistant", "id": "mailbox-boundary", "phase": "commentary",
        "content": [["type": "output_text", "text": "Waiting for the report."]],
      ],
    ])
  }

  private func wait(until ready: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(30)
    while !ready() {
      guard condition.wait(until: deadline) || ready() else {
        throw RouterFailure("The scripted mailbox exchange did not reach its next boundary.")
      }
    }
  }

  private static func function(_ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
    [
      "type": "function_call", "id": name, "call_id": "mailbox-" + name,
      "namespace": "collaboration", "name": name, "arguments": try RouterJSON.string(arguments),
    ]
  }

  private static func message(_ text: String) -> [String: Any] {
    [
      "type": "message", "role": "assistant", "id": text, "phase": "final_answer",
      "content": [["type": "output_text", "text": text]],
    ]
  }
}

private final class MailboxUpstream: RouterUpstream, @unchecked Sendable {
  let generation = UUID().uuidString
  let accountID: UUID
  private let model: MailboxModel
  private let condition = NSCondition()
  private var events: [Data] = []
  private var waitingForMail = false
  private var closed = false

  init(account: UUID, model: MailboxModel) {
    accountID = account
    self.model = model
  }

  func checkConnection() throws {}

  func send(_ data: Data) throws {
    let response = try model.response(data, account: accountID)
    condition.lock()
    (events, waitingForMail) = response
    condition.broadcast()
    condition.unlock()
  }

  func receive() throws -> Data {
    condition.lock()
    if !events.isEmpty {
      let event = events.removeFirst()
      condition.unlock()
      return event
    }
    if waitingForMail {
      waitingForMail = false
      condition.unlock()
      return try model.commentaryDone()
    }
    defer { condition.unlock() }
    while !closed { condition.wait() }
    var failure = RouterTransportFailure(
      phase: .receive, error: URLError(.cancelled), closeCode: .invalid)
    failure.cause = .localClose
    throw failure
  }

  func close() {
    condition.lock()
    closed = true
    condition.broadcast()
    condition.unlock()
  }
}
