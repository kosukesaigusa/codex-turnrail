import Foundation
import Testing

@testable import CodexTurnrailCore

/// Exercise response waiting through the signed Engine and real Foundation WebSockets.
enum OfficialEngineWaitingFixture {
  enum Scenario { case cancellation, engineTimeout, delayedResponse }

  static func verify(app: URL, router: URL) throws {
    for scenario in [Scenario.cancellation, .engineTimeout, .delayedResponse] {
      try verify(scenario, app: app, router: router)
    }
  }

  private static func verify(_ scenario: Scenario, app: URL, router: URL) throws {
    let root = try RouterTestDirectory()
    let provider = try FixtureAccounts(root: root.url)
    let server = try WaitingModelServer(delayedResponse: scenario == .delayedResponse)
    defer { server.stop() }
    let runtime = try RouterRuntime(
      root: root.url, accounts: provider,
      connect: { account, _ in server.connect(account: account.account.id) })
    runtime.start()
    defer { runtime.stop() }
    let home = root.url.appending(path: "home")
    try RouterJSON.privateDirectory(home)
    try RouterJSON.writePrivate(
      RouterJSON.data(["OPENAI_API_KEY": "SYNTHETIC_LOCAL_WAITING_TEST"]),
      to: home.appending(path: "auth.json"))
    let engine = app.appending(path: "Contents/Resources/codex")
    var overrides = try runtime.configuration(engine: engine, home: home, executable: router)
    overrides += [
      "cli_auth_credentials_store=\"file\"", "model=\"gpt-5.6-luna\"",
      "model_reasoning_effort=\"low\"", "features.apps=false", "features.plugins=false",
      "features.memories=false", "analytics.enabled=false", "web_search=\"disabled\"",
      "approval_policy=\"never\"", "sandbox_mode=\"read-only\"",
    ]
    if scenario == .engineTimeout {
      // Built-in providers cannot be overridden. A local fixture provider lets
      // the unmodified Engine exercise its idle deadline without a five-minute wait.
      let endpoint = "http://127.0.0.1:\(runtime.listener.port)/\(runtime.secret)/v1"
      overrides += [
        "model_provider=\"waiting_fixture\"",
        "model_providers.waiting_fixture={name=\"OpenAI\",base_url="
          + RouterJSON.quote(endpoint)
          + ",wire_api=\"responses\",requires_openai_auth=true,"
          + "supports_websockets=true,stream_idle_timeout_ms=1000}",
      ]
    }
    let rpc = try OfficialEngineRPC(
      engine: engine, home: home, overrides: overrides, timeoutSeconds: 230)
    defer { rpc.close() }
    let created = try rpc.request("thread/start", ["cwd": root.url.path, "ephemeral": true])
    let thread = try RouterJSON.text(RouterJSON.map(created, "thread"), "id")
    let started = try rpc.request(
      "turn/start",
      [
        "threadId": thread,
        "input": [["type": "text", "text": "Wait for the fixture response.", "text_elements": []]],
      ])
    let turn = try RouterJSON.text(RouterJSON.map(started, "turn"), "id")
    try #require(server.requestReceived.wait(timeout: .now() + 10) == .success)
    let waitingAt = ProcessInfo.processInfo.systemUptime
    if scenario == .cancellation {
      _ = try rpc.request("turn/interrupt", ["threadId": thread, "turnId": turn])
    }
    let result = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
    switch scenario {
    case .cancellation:
      try #require(result["status"] as? String == "interrupted")
      try #require(server.disconnected.wait(timeout: .now() + 5) == .success)
      #expect(ProcessInfo.processInfo.systemUptime - waitingAt < 10)
    case .engineTimeout:
      try #require(result["status"] as? String == "failed")
      try #require(server.disconnected.wait(timeout: .now() + 5) == .success)
      #expect(ProcessInfo.processInfo.systemUptime - waitingAt >= 1)
      #expect(ProcessInfo.processInfo.systemUptime - waitingAt < 20)
    case .delayedResponse:
      try #require(result["status"] as? String == "completed")
      let items = try rpc.takeNotifications("item/completed")
      #expect(try RouterJSON.string(["items": items]).contains("Quiet response completed"))
      #expect(try #require(server.responseDelay) >= 181)
    }
    // Engine retries, if any, must stop at the ledger; upstream inference occurs once.
    #expect(server.requests.count == 1)
    #expect(!server.accounts.isEmpty)
    #expect(server.accounts.allSatisfy { $0 == provider.first.account.id })
  }
}

private final class WaitingModelServer: @unchecked Sendable {
  private let listener: RouterListener
  private let lock = NSLock()
  private var received: [Data] = []
  private var opened: [UUID] = []
  private var replies: [DispatchWorkItem] = []
  private var elapsed: TimeInterval?
  let requestReceived = DispatchSemaphore(value: 0)
  let disconnected = DispatchSemaphore(value: 0)
  var requests: [Data] { lock.withLock { received } }
  var accounts: [UUID] { lock.withLock { opened } }
  var responseDelay: TimeInterval? { lock.withLock { elapsed } }

  init(delayedResponse: Bool) throws {
    listener = try RouterListener()
    listener.start { [weak self] socket in
      guard let self else { return }
      defer { self.disconnected.signal() }
      do {
        try socket.upgrade(socket.request())
        while let request = try socket.message() {
          self.lock.withLock { self.received.append(request) }
          try socket.frame(
            RouterJSON.data(["type": "response.created", "response": ["id": "quiet-response"]]))
          let waitingAt = ProcessInfo.processInfo.systemUptime
          self.requestReceived.signal()
          if delayedResponse {
            let reply = DispatchWorkItem { [weak self] in
              guard let self else { return }
              do {
                let item: [String: Any] = [
                  "id": "quiet-item", "type": "message", "role": "assistant",
                  "content": [["type": "output_text", "text": "Quiet response completed"]],
                ]
                try socket.frame(
                  RouterJSON.data(["type": "response.output_item.done", "item": item]))
                self.lock.withLock {
                  self.elapsed = ProcessInfo.processInfo.systemUptime - waitingAt
                }
                try socket.frame(
                  RouterJSON.data([
                    "type": "response.completed",
                    "response": [
                      "id": "quiet-response",
                      "usage": ["input_tokens": 1, "output_tokens": 1, "total_tokens": 2],
                    ],
                  ]))
              } catch { Issue.record(error) }
            }
            self.lock.withLock { self.replies.append(reply) }
            // Exercise more than three minutes of model silence with transport pongs only.
            DispatchQueue.global().asyncAfter(deadline: .now() + 181, execute: reply)
          }
        }
      } catch {
        // Engine cancellation may close TCP without completing a WebSocket close handshake.
      }
    }
  }

  func connect(account: UUID) -> RouterWebSocket {
    lock.withLock { opened.append(account) }
    return RouterWebSocket(
      accountID: account,
      request: URLRequest(url: URL(string: "ws://127.0.0.1:\(listener.port)/responses")!),
      policy: .live)
  }

  func stop() {
    lock.withLock { for reply in replies { reply.cancel() } }
    listener.stop()
  }
}
