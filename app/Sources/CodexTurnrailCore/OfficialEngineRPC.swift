import Darwin
import Foundation

/// A bounded, isolated protocol client for configuration and account inspection.
final class OfficialEngineRPC: @unchecked Sendable {
  private let process: RouterEngineProcess
  private let reader: EngineLineReader
  private var nextID = 1
  private var notifications: [[String: Any]] = []
  private let timeout: DispatchWorkItem

  init(engine: URL, home: URL, overrides: [String], timeoutSeconds: Double = 30) throws {
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = home.path
    environment["CODEX_CLI_PATH"] = engine.path
    environment.removeValue(forKey: "CODEX_TURNRAIL_ROOT")
    environment.removeValue(forKey: "CODEX_TURNRAIL_APP")
    let process = try RouterEngineProcess(
      executable: engine,
      arguments: ["app-server", "--listen", "stdio://"] + overrides.flatMap { ["-c", $0] },
      environment: environment, error: FileHandle.nullDevice)
    self.process = process
    reader = EngineLineReader(process.output)
    timeout = DispatchWorkItem { process.forceTerminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
    do {
      _ = try request(
        "initialize",
        [
          "clientInfo": ["name": "codex-turnrail", "version": "1"],
          "capabilities": ["experimentalApi": true],
        ])
      try send(["method": "initialized"])
    } catch {
      close()
      throw error
    }
  }

  func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
    let id = nextID
    nextID += 1
    try send(["id": id, "method": method, "params": params])
    while let raw = try reader.next() {
      let message = try RouterJSON.object(raw)
      guard message["method"] == nil, message["id"] as? Int == id else {
        notifications.append(message)
        guard notifications.count < 10000 else {
          throw RouterFailure("Too many unmatched Engine notifications.")
        }
        continue
      }
      if let error = message["error"] as? [String: Any] {
        let failure = try AccountServerFailureParser.parse(response: message, error: error)
        if failure.recoveryAction == .reauthenticate {
          throw RouterAccountUnavailable.loginRequired
        }
        throw RouterFailure("The official Engine rejected \(method).")
      }
      return try RouterJSON.map(message, "result")
    }
    throw RouterFailure(
      "The official Engine did not complete \(method) within the inspection deadline.")
  }

  func notification(
    _ method: String, requestHandler: ((String, [String: Any]) throws -> [String: Any])? = nil
  ) throws -> [String: Any] {
    while true {
      if let index = notifications.firstIndex(where: { $0["method"] != nil && $0["id"] != nil }) {
        let request = notifications.remove(at: index)
        guard let requestHandler else { throw RouterFailure("Unexpected Engine approval request.") }
        let result = try requestHandler(
          RouterJSON.text(request, "method"), RouterJSON.map(request, "params"))
        try send(["id": request["id"]!, "result": result])
        continue
      }
      if let index = notifications.firstIndex(where: { $0["method"] as? String == method }) {
        return try RouterJSON.map(notifications.remove(at: index), "params")
      }
      guard let raw = try reader.next() else {
        throw RouterFailure("The Engine stopped before \(method).")
      }
      notifications.append(try RouterJSON.object(raw))
      guard notifications.count < 10000 else {
        throw RouterFailure("Too many unmatched Engine notifications.")
      }
    }
  }

  private func send(_ value: [String: Any]) throws {
    var data = try RouterJSON.data(value)
    data.append(0x0A)
    try process.input.write(contentsOf: data)
  }

  func takeNotifications(_ method: String) throws -> [[String: Any]] {
    let selected = notifications.filter { $0["method"] as? String == method && $0["id"] == nil }
    notifications.removeAll { $0["method"] as? String == method && $0["id"] == nil }
    return try selected.map { try RouterJSON.map($0, "params") }
  }

  func close() {
    timeout.cancel()
    try? process.input.close()
    process.stop()
  }
}

/// Buffered pipe reads preserve NDJSON boundaries without a syscall per byte.
final class EngineLineReader {
  private let handle: FileHandle
  private var buffer = Data()
  init(_ handle: FileHandle) { self.handle = handle }

  func next() throws -> Data? {
    while true {
      if let end = buffer.firstIndex(of: 0x0A) {
        guard buffer.distance(from: buffer.startIndex, to: end) <= 64 * 1024 * 1024 else {
          throw RouterFailure("Engine protocol message exceeds the supported size.")
        }
        let line = Data(buffer[..<end])
        buffer.removeSubrange(...end)
        return line
      }
      guard buffer.count <= 64 * 1024 * 1024 else {
        throw RouterFailure("Engine protocol message exceeds the supported size.")
      }
      var chunk = [UInt8](repeating: 0, count: 65536)
      let count = Darwin.read(handle.fileDescriptor, &chunk, chunk.count)
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw RouterFailure("Could not read the Engine protocol pipe.") }
      if count == 0 {
        guard buffer.isEmpty else { throw RouterFailure("The Engine protocol ended mid-message.") }
        return nil
      }
      buffer.append(contentsOf: chunk.prefix(count))
    }
  }
}

enum RouterAccountUnavailable: LocalizedError {
  case loginRequired
  case exhausted
  var errorDescription: String? {
    switch self {
    case .loginRequired: "The account needs to sign in again."
    case .exhausted: "The account's usage limit is exhausted."
    }
  }
}
