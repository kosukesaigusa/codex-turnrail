import Darwin
import Foundation

/// Only typed counters, timings, and protocol codes enter the diagnostic archive.
struct RouterTransportObservation: Codable, Sendable {
  enum Kind: String, Codable { case turn, compaction }
  let kind: Kind
  let connectionReused: Bool
  let requestBytes: Int
  let elapsedMS: Int
  let silenceMS: Int
  let receivedEvents: Int
  let responseStarted: Bool
}

struct RouterRequestProgress {
  let kind: RouterTransportObservation.Kind
  let connectionReused: Bool
  let requestBytes: Int
  private let startedAt = ProcessInfo.processInfo.systemUptime
  private var lastEventAt: TimeInterval?
  private var receivedEvents = 0
  private var responseStarted = false

  init(kind: RouterTransportObservation.Kind, connectionReused: Bool, requestBytes: Int) {
    self.kind = kind
    self.connectionReused = connectionReused
    self.requestBytes = requestBytes
  }

  mutating func received(type: String) {
    lastEventAt = ProcessInfo.processInfo.systemUptime
    receivedEvents += 1
    if type == "response.created" { responseStarted = true }
  }

  func snapshot() -> RouterTransportObservation {
    let now = ProcessInfo.processInfo.systemUptime
    let quietSince: TimeInterval
    if let lastEventAt { quietSince = lastEventAt } else { quietSince = startedAt }
    return RouterTransportObservation(
      kind: kind, connectionReused: connectionReused, requestBytes: requestBytes,
      elapsedMS: Int((now - startedAt) * 1000), silenceMS: Int((now - quietSince) * 1000),
      receivedEvents: receivedEvents, responseStarted: responseStarted)
  }
}

final class RouterTransportLog: @unchecked Sendable {
  struct Entry: Codable {
    let reference: String
    let time: Date
    let phase: RouterTransportFailure.Phase
    let cause: RouterTransportFailure.Cause
    let domain: String?
    let code: Int?
    let closeCode: Int?
    let connectionAgeMS: Int?
    let request: RouterTransportObservation?
  }

  private struct Archive: Codable {
    let schemaVersion: Int
    var entries: [Entry]
  }

  static let maximumEntries = 64
  private static let maximumBytes = 256 * 1024
  private let file: URL
  private let lock = NSLock()

  init(root: URL) { file = root.appending(path: "transport-diagnostics.json") }

  func record(_ failure: RouterTransportFailure) throws -> String {
    try lock.withLock {
      let reference = UUID().uuidString.lowercased()
      var archive = try read()
      archive.entries.append(
        Entry(
          reference: reference, time: Date(), phase: failure.phase, cause: failure.cause,
          domain: failure.domain, code: failure.code, closeCode: failure.closeCode,
          connectionAgeMS: failure.connectionAgeMS, request: failure.request))
      archive.entries = Array(archive.entries.suffix(Self.maximumEntries))
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(archive)
      guard data.count <= Self.maximumBytes else {
        throw RouterFailure("Transport diagnostics exceed their storage limit.")
      }
      try RouterJSON.writePrivate(data, to: file)
      return reference
    }
  }

  private func read() throws -> Archive {
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    if descriptor < 0 {
      guard errno == ENOENT else { throw RouterFailure("Could not open transport diagnostics.") }
      return Archive(schemaVersion: 1, entries: [])
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= Self.maximumBytes,
      let data = try handle.read(upToCount: Self.maximumBytes + 1),
      data.count <= Self.maximumBytes
    else { throw RouterFailure("Transport diagnostics must be a bounded, owned regular file.") }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let archive = try decoder.decode(Archive.self, from: data)
    guard archive.schemaVersion == 1, archive.entries.count <= Self.maximumEntries else {
      throw RouterFailure("Unsupported transport diagnostic archive.")
    }
    return archive
  }
}
