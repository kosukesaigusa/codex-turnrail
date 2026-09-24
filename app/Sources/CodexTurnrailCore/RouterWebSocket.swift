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
  private let policy: RouterConnectionPolicy
  private let stateLock = NSLock()
  private let probeLock = NSLock()
  private let keeper: DispatchSourceTimer
  private let createdAt = ProcessInfo.processInfo.systemUptime
  private var incoming = RouterAsyncResult<Data>()
  private var pendingProbe: RouterAsyncResult<Void>?
  private var pendingSend: RouterAsyncResult<Void>?
  private var terminal: Error?

  convenience init(account: RouterAccountSnapshot, headers: [String: String]) {
    var request = URLRequest(url: URL(string: "wss://chatgpt.com/backend-api/codex/responses")!)
    request.allHTTPHeaderFields = account.credential.headers
    for name in [
      "openai-beta", "version", "originator", "x-codex-beta-features", "session_id",
      "conversation_id", "x-client-request-id", "x-openai-internal-codex-responses-lite",
    ] {
      if let value = headers[name] { request.setValue(value, forHTTPHeaderField: name) }
    }
    self.init(accountID: account.account.id, request: request, policy: .live)
  }

  init(accountID: UUID, request: URLRequest, policy: RouterConnectionPolicy) {
    self.policy = policy
    self.accountID = accountID
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    session = URLSession(configuration: configuration, delegate: RouterHTTP(), delegateQueue: nil)
    task = session.webSocketTask(with: request)
    task.maximumMessageSize = 64 * 1024 * 1024
    keeper = DispatchSource.makeTimerSource(
      queue: DispatchQueue(label: "Turnrail.websocket.keepalive"))
    keeper.schedule(deadline: .now() + policy.keepAlive, repeating: policy.keepAlive)
    keeper.setEventHandler { [weak self] in
      // Failed probes close the transport and wake readers; inference is never resent.
      do { try self?.probe(cause: .keepAlive) } catch {}
    }
    keeper.resume()
    task.resume()
    readNext(incoming)
  }

  deinit { close() }

  /// Serialize foreground and periodic pings, including while model output is quiet.
  func checkConnection() throws { try probe(cause: .probe) }

  private func probe(cause: RouterTransportFailure.Cause) throws {
    try probeLock.withLock {
      let result = RouterAsyncResult<Void>()
      try stateLock.withLock {
        if let terminal { throw inPhase(terminal, .check) }
        pendingProbe = result
      }
      defer { stateLock.withLock { pendingProbe = nil } }
      task.sendPing { [weak self] error in
        guard let self else { return }
        if let error {
          result.complete(.failure(self.fail(.check, error, cause: cause)))
        } else {
          result.complete(.success(()))
        }
      }
      do { try result.wait(seconds: policy.probe, timeout: URLError(.timedOut)) } catch {
        throw fail(.check, error, cause: cause)
      }
      // The receive callback may have observed closure after the pong arrived.
      try stateLock.withLock {
        if let terminal { throw inPhase(terminal, .check) }
      }
    }
  }

  func send(_ data: Data) throws {
    let result = RouterAsyncResult<Void>()
    try stateLock.withLock {
      if let terminal { throw inPhase(terminal, .send) }
      pendingSend = result
    }
    defer { stateLock.withLock { pendingSend = nil } }
    Task { [weak self, task] in
      do {
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
        result.complete(.success(()))
      } catch {
        guard let self else { return }
        result.complete(.failure(self.fail(.send, error, cause: .transport)))
      }
    }
    do { try result.wait(seconds: policy.send, timeout: URLError(.timedOut)) } catch {
      throw fail(.send, error, cause: .sendTimeout)
    }
  }

  func receive() throws -> Data {
    let pending = stateLock.withLock { incoming }
    let data: Data
    do { data = try pending.wait(seconds: policy.receive, timeout: URLError(.timedOut)) } catch {
      throw fail(.receive, error, cause: .receiveTimeout)
    }
    let next = RouterAsyncResult<Data>()
    let shouldRead = stateLock.withLock {
      incoming = next
      if let terminal {
        next.complete(.failure(terminal))
        return false
      }
      return true
    }
    if shouldRead { readNext(next) }
    return data
  }

  private func readNext(_ result: RouterAsyncResult<Data>) {
    // One bounded receive remains pending between requests so Foundation handles controls.
    Task { [weak self, task] in
      do {
        switch try await task.receive() {
        case .string(let value): result.complete(.success(Data(value.utf8)))
        case .data:
          throw RouterFailure("The account returned an unsupported binary response.")
        @unknown default:
          throw RouterFailure("The account returned an unknown WebSocket message.")
        }
      } catch {
        guard let self else { return }
        result.complete(.failure(self.fail(.receive, error, cause: .transport)))
      }
    }
  }

  private func inPhase(_ error: Error, _ phase: RouterTransportFailure.Phase) -> Error {
    guard var failure = error as? RouterTransportFailure else { return error }
    failure.phase = phase
    return failure
  }

  private func fail(
    _ phase: RouterTransportFailure.Phase, _ error: Error, cause: RouterTransportFailure.Cause
  ) -> Error {
    let failure: Error
    if error is RouterTransportFailure || error is RouterFailure {
      failure = error
    } else {
      var transport = RouterTransportFailure(phase: phase, error: error, closeCode: task.closeCode)
      transport.cause = cause
      transport.connectionAgeMS = Int((ProcessInfo.processInfo.systemUptime - createdAt) * 1000)
      failure = transport
    }
    // Preserve the first cause instead of replacing it with cancellation side effects.
    let (saved, stopped): (Error, Bool) = stateLock.withLock {
      if let terminal { return (terminal, false) }
      terminal = failure
      incoming.complete(.failure(failure))
      pendingProbe?.complete(.failure(failure))
      pendingSend?.complete(.failure(failure))
      return (failure, true)
    }
    if stopped {
      keeper.cancel()
      task.cancel(with: .goingAway, reason: nil)
      session.invalidateAndCancel()
    }
    return inPhase(saved, phase)
  }

  func close() { _ = fail(.check, URLError(.cancelled), cause: .localClose) }
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
