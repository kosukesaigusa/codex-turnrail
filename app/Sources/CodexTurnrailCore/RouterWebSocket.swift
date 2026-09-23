import Foundation

protocol RouterUpstream: Sendable {
  var generation: String { get }
  var accountID: UUID { get }
  func checkConnection() throws
  func send(_ data: Data) throws
  func receive() throws -> Data
  func close()
}

final class RouterWebSocket: RouterUpstream, @unchecked Sendable {
  let generation = UUID().uuidString
  let accountID: UUID
  private let session: URLSession
  private let task: URLSessionWebSocketTask
  private let delegate: RouterHTTP
  private var incoming = RouterAsyncResult<Data>()

  convenience init(account: RouterAccountSnapshot, headers: [String: String]) {
    var request = URLRequest(url: URL(string: "wss://chatgpt.com/backend-api/codex/responses")!)
    request.allHTTPHeaderFields = account.credential.headers
    for name in [
      "openai-beta", "version", "originator", "x-codex-beta-features", "session_id",
      "conversation_id", "x-client-request-id", "x-openai-internal-codex-responses-lite",
    ] {
      if let value = headers[name] { request.setValue(value, forHTTPHeaderField: name) }
    }
    self.init(accountID: account.account.id, request: request)
  }

  init(accountID: UUID, request: URLRequest) {
    let delegate = RouterHTTP()
    self.delegate = delegate
    self.accountID = accountID
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    task = session.webSocketTask(with: request)
    task.maximumMessageSize = 64 * 1024 * 1024
    task.resume()
    readNext(incoming)
  }

  /// A pong confirms liveness without submitting a model request.
  func checkConnection() throws {
    let result = RouterAsyncResult<Void>()
    task.sendPing { error in
      if let error {
        result.complete(.failure(self.failure(.check, error)))
      } else {
        result.complete(.success(()))
      }
    }
    try result.wait(seconds: 10, timeout: failure(.check, URLError(.timedOut)))
  }

  func send(_ data: Data) throws {
    let result = RouterAsyncResult<Void>()
    Task {
      do {
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
        result.complete(.success(()))
      } catch {
        result.complete(.failure(failure(.send, error)))
      }
    }
    try result.wait(seconds: 30, timeout: failure(.send, URLError(.timedOut)))
  }

  func receive() throws -> Data {
    let data = try incoming.wait(
      seconds: 180, timeout: failure(.receive, URLError(.timedOut)))
    incoming = RouterAsyncResult<Data>()
    readNext(incoming)
    return data
  }

  private func readNext(_ result: RouterAsyncResult<Data>) {
    // Keep one bounded receive pending between requests. Foundation otherwise
    // stops delivering pong/close callbacks after a consumed text message.
    let task = task
    Task {
      do {
        switch try await task.receive() {
        case .string(let value): result.complete(.success(Data(value.utf8)))
        case .data:
          result.complete(
            .failure(RouterFailure("The account returned an unsupported binary response.")))
        @unknown default:
          result.complete(
            .failure(RouterFailure("The account returned an unknown WebSocket message.")))
        }
      } catch {
        result.complete(
          .failure(RouterTransportFailure(phase: .receive, error: error, closeCode: task.closeCode))
        )
      }
    }
  }

  private func failure(_ phase: RouterTransportFailure.Phase, _ error: Error)
    -> RouterTransportFailure
  {
    RouterTransportFailure(phase: phase, error: error, closeCode: task.closeCode)
  }

  func close() {
    task.cancel(with: .goingAway, reason: nil)
    session.invalidateAndCancel()
  }
}

private final class RouterAsyncResult<T: Sendable>: @unchecked Sendable {
  private let ready = DispatchSemaphore(value: 0)
  private var result: Result<T, Error>?
  func complete(_ result: Result<T, Error>) {
    self.result = result
    ready.signal()
  }
  func wait(seconds: Double, timeout: @autoclosure () -> Error) throws -> T {
    guard ready.wait(timeout: .now() + seconds) == .success, let result else {
      throw timeout()
    }
    return try result.get()
  }
}

/// One receiver detects cancellation while the response worker waits on upstream.
final class RouterMessages: @unchecked Sendable {
  private let condition = NSCondition()
  private var messages: [Data] = []
  private var stopped = false
  private var upstream: (any RouterUpstream)?

  func start(_ socket: RouterSocket) {
    socket.onClose { self.stop() }
    DispatchQueue(label: "Turnrail.websocket.receiver").async {
      defer { self.stop() }
      do {
        while let message = try socket.message() {
          self.condition.lock()
          if self.stopped || self.messages.count >= 8 {
            self.condition.unlock()
            break
          }
          self.messages.append(message)
          self.condition.signal()
          self.condition.unlock()
        }
      } catch {}
    }
  }

  func next() -> Data? {
    condition.lock()
    defer { condition.unlock() }
    while !stopped && messages.isEmpty { condition.wait() }
    if stopped { return nil }
    return messages.removeFirst()
  }

  func attach(_ socket: any RouterUpstream) throws {
    condition.lock()
    defer { condition.unlock() }
    guard !stopped else {
      socket.close()
      throw RouterFailure("The desktop cancelled the request.")
    }
    upstream?.close()
    upstream = socket
  }

  func stop() {
    condition.lock()
    stopped = true
    upstream?.close()
    upstream = nil
    condition.broadcast()
    condition.unlock()
  }
}

enum RouterRequest {
  /// Persist client deltas; content-addressed messages avoid repeated full conversation copies.
  static func history(_ body: [String: Any], thread: String, output: [[String: Any]]) throws
    -> [String: Any]
  {
    var result: [String: Any] = [
      "thread": thread, "input": try RouterJSON.array(body, "input"), "output": output,
    ]
    if body["previous_response_id"] != nil && !(body["previous_response_id"] is NSNull) {
      result["previous"] = try RouterJSON.text(body, "previous_response_id")
    }
    return result
  }

  static func metadata(_ body: [String: Any]) throws -> [String: Any] {
    guard body["type"] as? String == "response.create" else {
      throw RouterFailure("Only response.create is supported.")
    }
    let client = try RouterJSON.map(body, "client_metadata")
    for key in ["x-codex-turn-state", "x-codex-routing-hint"] where client[key] != nil {
      throw RouterFailure("Account-specific routing state cannot be reused across accounts.")
    }
    let metadata = try RouterJSON.object(
      Data(RouterJSON.text(client, "x-codex-turn-metadata").utf8))
    guard ["turn", "compaction", "prewarm"].contains(try RouterJSON.text(metadata, "request_kind"))
    else {
      throw RouterFailure("The model request has no supported routing purpose.")
    }
    return metadata
  }

  static func binding(_ metadata: [String: Any], ledger: RouterLedger) throws -> (String, UUID) {
    let thread = try RouterJSON.text(metadata, "thread_id")
    let key = try RouterLedger.key(thread, RouterJSON.text(metadata, "turn_id"))
    // Both fields are optional in the official Engine protocol. A normal turn
    // without them still requires the exact prompt-hook binding below.
    let source = try optionalMetadataText(metadata, "thread_source")
    let trigger = try optionalMetadataText(metadata, "turn_trigger")
    if source == "thread_title" || trigger == "thread_title" {
      guard source == "thread_title", trigger == "thread_title",
        metadata["request_kind"] as? String == "turn",
        let account = try ledger.title(thread)
      else {
        throw RouterFailure("The automatic title task was not registered by the Engine observer.")
      }
      try ledger.bind(key, account: account)
    } else {
      guard try ledger.title(thread) == nil else {
        throw RouterFailure("Title task classification changed.")
      }
      if source == "subagent" || source == "guardian_review" {
        let parent = try RouterLedger.key(
          RouterJSON.text(metadata, "parent_thread_id"), RouterJSON.text(metadata, "parent_turn_id")
        )
        guard let account = try ledger.bound(parent) else {
          throw RouterFailure("A child request requires its parent turn binding.")
        }
        try ledger.bind(key, account: account)
      }
    }
    guard let account = try ledger.bound(key) else {
      throw RouterFailure("No prompt-hook binding exists for this turn.")
    }
    return (key, account)
  }

  private static func optionalMetadataText(_ metadata: [String: Any], _ key: String) throws
    -> String?
  {
    guard metadata[key] != nil else { return nil }
    return try RouterJSON.text(metadata, key)
  }

  static func expanded(_ body: [String: Any], thread: String, ledger: RouterLedger) throws -> (
    [[String: Any]], [String: Any]?
  ) {
    let input = try RouterJSON.array(body, "input")
    if body["previous_response_id"] == nil || body["previous_response_id"] is NSNull {
      return (input, nil)
    }
    let previous = try ledger.history(RouterJSON.text(body, "previous_response_id"), thread: thread)
    return (
      try RouterJSON.array(previous, "input") + RouterJSON.array(previous, "output") + input,
      previous
    )
  }

  static func payload(
    _ body: [String: Any], input: [[String: Any]], previous: [String: Any]?, account: UUID,
    generation: String
  ) -> [String: Any] {
    var result = body
    if previous?["account"] as? String != account.uuidString.lowercased()
      || previous?["generation"] as? String != generation
    {
      result.removeValue(forKey: "previous_response_id")
      result["input"] = input
    }
    return result
  }

  static func fingerprint(_ body: [String: Any], input: [[String: Any]], turn: String) throws
    -> String
  {
    var identity = body
    identity.removeValue(forKey: "previous_response_id")
    identity.removeValue(forKey: "client_metadata")
    identity["input"] = input
    return RouterJSON.hash(try RouterJSON.data(["turn": turn, "request": identity]))
  }
}
