import Foundation

/// One HTTP inference exchange. The official Engine owns retries and stream timeouts.
final class RouterEventStream: NSObject, RouterUpstream, URLSessionDataDelegate,
  @unchecked Sendable
{
  let generation = UUID().uuidString
  let accountID: UUID
  private let condition = NSCondition()
  private let request: URLRequest
  private var session: URLSession!
  private var task: URLSessionDataTask?
  private var events: [Data] = []
  private var queuedBytes = 0
  private var parser = RouterSSEParser()
  private var terminal: Error?
  private var status: Int?
  private var rejection = Data()
  private let createdAt = ProcessInfo.processInfo.systemUptime

  convenience init(account: RouterAccountSnapshot, headers: [String: String]) {
    var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/responses")!)
    request.httpMethod = "POST"
    request.allHTTPHeaderFields = account.credential.headers
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    for name in [
      "openai-beta", "version", "originator", "x-codex-beta-features", "session_id",
      "conversation_id", "x-client-request-id", "x-openai-internal-codex-responses-lite",
      "x-codex-turn-metadata",
    ] {
      if let value = headers[name] { request.setValue(value, forHTTPHeaderField: name) }
    }
    self.init(accountID: account.account.id, request: request)
  }

  init(accountID: UUID, request: URLRequest) {
    self.accountID = accountID
    self.request = request
    super.init()
    let configuration = URLSessionConfiguration.ephemeral
    // No additional model-response deadline; closing the Engine connection cancels us.
    configuration.timeoutIntervalForRequest = .infinity
    configuration.timeoutIntervalForResource = .infinity
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }

  func checkConnection() throws {
    condition.lock()
    defer { condition.unlock() }
    if let terminal { throw terminal }
  }

  func send(_ data: Data) throws {
    var body = try RouterJSON.object(data)
    guard body.removeValue(forKey: "type") as? String == "response.create" else {
      throw RouterFailure("HTTP inference requires a response.create envelope.")
    }
    let metadata = try RouterJSON.map(body, "client_metadata")
    var request = self.request
    request.setValue(
      try RouterJSON.text(metadata, "x-codex-turn-metadata"),
      forHTTPHeaderField: "x-codex-turn-metadata")
    request.httpBody = try RouterJSON.data(body)
    condition.lock()
    defer { condition.unlock() }
    if let terminal { throw terminal }
    guard task == nil else { throw RouterFailure("An HTTP inference cannot be submitted twice.") }
    let task = session.dataTask(with: request)
    self.task = task
    task.resume()
  }

  func receive() throws -> Data {
    condition.lock()
    defer { condition.unlock() }
    while events.isEmpty && terminal == nil { condition.wait() }
    if !events.isEmpty {
      let event = events.removeFirst()
      queuedBytes -= event.count
      return event
    }
    throw terminal!
  }

  func close() {
    var failure = RouterTransportFailure(
      phase: .receive, error: URLError(.cancelled), closeCode: .invalid)
    failure.cause = .localClose
    finish(failure)
    session.invalidateAndCancel()
  }

  private func finish(_ error: Error) {
    condition.lock()
    if terminal == nil { terminal = error }
    condition.broadcast()
    condition.unlock()
  }

  private func connectionFailure(_ error: Error) -> RouterTransportFailure {
    var failure = RouterTransportFailure(phase: .receive, error: error, closeCode: .invalid)
    failure.connectionAgeMS = Int((ProcessInfo.processInfo.systemUptime - createdAt) * 1000)
    return failure
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let response = response as? HTTPURLResponse else {
      finish(RouterFailure("The model service returned an invalid HTTP response."))
      completionHandler(.cancel)
      return
    }
    status = response.statusCode
    if response.statusCode == 200, response.mimeType?.lowercased() != "text/event-stream" {
      finish(RouterFailure("The model service did not return an event stream."))
      completionHandler(.cancel)
    } else {
      completionHandler(.allow)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    do {
      if status != 200 {
        guard rejection.count + data.count <= 16384 else {
          throw RouterFailure("The model service returned an oversized HTTP rejection.")
        }
        rejection.append(data)
        return
      }
      condition.lock()
      defer { condition.unlock() }
      guard terminal == nil else { return }
      guard queuedBytes + parser.bufferedBytes + data.count <= RouterSSEParser.maximumBytes else {
        throw RouterFailure("The model event stream exceeded the supported buffer size.")
      }
      let received = try parser.append(data)
      events += received
      queuedBytes += received.reduce(0) { $0 + $1.count }
      condition.signal()
    } catch {
      finish(error)
      dataTask.cancel()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let status, status != 200 {
      // A known rejection remains terminal even if its body delivery was interrupted.
      do {
        let body = try RouterJSON.object(rejection)
        let detail = try RouterJSON.map(body, "error")
        finish(
          try RouterServiceFailure(event: ["type": "error", "status": status, "error": detail]))
      } catch {
        finish(RouterFailure("The model service rejected HTTP inference (HTTP \(status))."))
      }
    } else {
      // Even clean EOF is incomplete without response.completed. The consumer will
      // already have committed a completed response before reading this sentinel.
      finish(connectionFailure(error ?? URLError(.networkConnectionLost)))
    }
  }
}

/// Incremental SSE framing with a bounded UTF-8 event, including split CRLF delimiters.
struct RouterSSEParser {
  static let maximumBytes = 64 * 1024 * 1024
  private var pending = Data()
  private var payload = Data()
  private var afterCR = false
  var bufferedBytes: Int { pending.count + payload.count }

  mutating func append(_ chunk: Data) throws -> [Data] {
    guard bufferedBytes + chunk.count <= Self.maximumBytes else {
      throw RouterFailure("The model event exceeded the supported size.")
    }
    var events: [Data] = []
    for byte in chunk {
      if afterCR {
        afterCR = false
        if byte == 10 { continue }
      }
      if byte == 10 || byte == 13 {
        afterCR = byte == 13
        if pending.isEmpty {
          if !payload.isEmpty {
            payload.removeLast()
            guard String(data: payload, encoding: .utf8) != nil else {
              throw RouterFailure("Invalid model event encoding.")
            }
            if payload != Data("[DONE]".utf8) { events.append(payload) }
            payload = Data()
          }
        } else if pending.starts(with: Data("data:".utf8)) {
          var value = pending.dropFirst(5)
          if value.first == 32 { value = value.dropFirst() }
          payload.append(contentsOf: value)
          payload.append(10)
        }
        pending = Data()
      } else {
        pending.append(byte)
      }
    }
    return events
  }
}
