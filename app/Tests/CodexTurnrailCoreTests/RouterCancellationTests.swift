import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterCancellationTests {
  @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
  func closedInferenceDoesNotBlockChangedInputOnTheSameTurn(http: Bool, bufferedEvent: Bool) throws
  {
    let root = try RouterTestDirectory()
    let accounts = try FixtureAccounts(root: root.url)
    let backend = FixtureModel()
    let handled = DispatchSemaphore(value: 0)
    backend.interrupt(after: 0, count: 1, at: .text, onInterruption: {})
    let runtime = try RouterRuntime(
      root: root.url, accounts: accounts,
      connect: { account, _ in
        CancellationUpstream(
          account: account.account.id, backend: backend, http: false, bufferedEvent: bufferedEvent)
      },
      connectHTTP: { account, _ in
        CancellationUpstream(
          account: account.account.id, backend: backend, http: true, bufferedEvent: bufferedEvent)
      },
      reportFailure: { _ in handled.signal() })
    runtime.start()
    defer { runtime.stop() }
    try runtime.ledger.bind("parent/turn", account: accounts.first.account.id)
    let client = Self.client(runtime, http: http)
    defer { client.close() }
    let original = try Self.body("Original input")
    try client.send(RouterJSON.data(original))
    #expect(try RouterJSON.object(client.receive())["type"] as? String == "response.created")
    #expect(
      try RouterJSON.object(client.receive())["type"] as? String == "response.output_text.delta")
    #expect(
      try RouterJSON.object(client.receive())["type"] as? String == "response.output_item.done")
    client.close()
    try #require(handled.wait(timeout: .now() + 10) == .success)
    try #require(try runtime.ledger.bound("parent/turn") == accounts.first.account.id)

    accounts.choose(accounts.second.account.id)
    let continued = Self.client(runtime, http: http)
    defer { continued.close() }
    try continued.send(RouterJSON.data(Self.body("Original input plus the arriving report")))
    #expect(try RouterJSON.object(continued.receive())["type"] as? String == "response.created")
    _ = try continued.receive()
    #expect(try RouterJSON.object(continued.receive())["type"] as? String == "response.completed")
    #expect(backend.requests(for: "turn").count == 2)
    #expect(backend.requests(for: "turn").allSatisfy { $0.account == accounts.first.account.id })

    let duplicate = Self.client(runtime, http: !http)
    defer { duplicate.close() }
    try duplicate.send(RouterJSON.data(original))
    let rejected = try RouterJSON.object(duplicate.receive())
    #expect(["error", "response.failed"].contains(rejected["type"] as? String))
    #expect(backend.requests(for: "turn").count == 2)
  }

  private static func body(_ input: String) throws -> [String: Any] {
    [
      "type": "response.create", "stream": true, "model": "gpt-5.6-luna",
      "input": [["type": "message", "role": "user", "content": input]],
      "client_metadata": [
        "x-codex-turn-metadata": try RouterJSON.string([
          "thread_id": "parent", "turn_id": "turn", "request_kind": "turn",
        ])
      ],
    ]
  }

  private static func client(_ runtime: RouterRuntime, http: Bool) -> any RouterUpstream {
    let scheme = http ? "http" : "ws"
    var request = URLRequest(
      url: URL(
        string: "\(scheme)://127.0.0.1:\(runtime.listener.port)/\(runtime.secret)/v1/responses")!)
    if http {
      request.httpMethod = "POST"
      return RouterEventStream(accountID: UUID(), request: request)
    }
    return RouterWebSocket(accountID: UUID(), request: request, policy: .live)
  }
}

/// Keep a partial response open until the Engine closes its downstream connection.
private final class CancellationUpstream: RouterUpstream, @unchecked Sendable {
  let generation = UUID().uuidString
  let accountID: UUID
  private let condition = NSCondition()
  private let backend: FixtureModel
  private let http: Bool
  private var bufferedEvent: Bool
  private var events: [Data] = []
  private var closed = false

  init(account: UUID, backend: FixtureModel, http: Bool, bufferedEvent: Bool) {
    accountID = account
    self.backend = backend
    self.http = http
    self.bufferedEvent = bufferedEvent
  }

  func checkConnection() throws {}

  func send(_ data: Data) throws {
    condition.lock()
    defer { condition.unlock() }
    events = try backend.response(data, account: accountID, transport: http ? "http" : "websocket")
    condition.broadcast()
  }

  func receive() throws -> Data {
    condition.lock()
    defer { condition.unlock() }
    while events.isEmpty && !closed { condition.wait() }
    if !events.isEmpty { return events.removeFirst() }
    if bufferedEvent {
      bufferedEvent = false
      return try RouterJSON.data([
        "type": "response.output_text.delta", "delta": String(repeating: "x", count: 1024 * 1024),
      ])
    }
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
