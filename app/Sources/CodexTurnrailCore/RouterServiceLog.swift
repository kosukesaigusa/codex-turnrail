import Darwin
import Foundation

/// Stores bounded classifications and field states without server text or account identifiers.
final class RouterServiceLog: @unchecked Sendable {
  struct Entry: Codable {
    let reference: String
    let time: Date
    let transport: String
    let eventType: String
    let envelope: RouterServiceFailure.Envelope
    let status: Int?
    let statusState: RouterServiceFailure.Field.State
    let errorType: RouterServiceFailure.Field
    let code: RouterServiceFailure.Field
    let reason: RouterServiceFailure.Field
    let retryDelay: RouterServiceRetryDelay
    let permitsEngineRecovery: Bool
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

  init(root: URL) { file = root.appending(path: "service-diagnostics.json") }

  func record(
    _ failure: RouterServiceFailure, request: RouterTransportObservation?,
    transport: RouterModelStream.Transport
  ) throws -> String {
    try lock.withLock {
      let reference = UUID().uuidString.lowercased()
      var archive = try read()
      archive.entries.append(
        Entry(
          reference: reference, time: Date(),
          transport: transport == .webSocket ? "websocket" : "http",
          eventType: failure.eventType, envelope: failure.envelope, status: failure.status,
          statusState: failure.statusState, errorType: failure.errorType, code: failure.code,
          reason: failure.reason, retryDelay: failure.retryDelay,
          permitsEngineRecovery: failure.permitsEngineRecovery, request: request))
      archive.entries = Array(archive.entries.suffix(Self.maximumEntries))
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      let data = try encoder.encode(archive)
      guard data.count <= Self.maximumBytes else {
        throw RouterFailure("Service diagnostics exceed their storage limit.")
      }
      try RouterJSON.writePrivate(data, to: file)
      return reference
    }
  }

  private func read() throws -> Archive {
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    if descriptor < 0 {
      guard errno == ENOENT else { throw RouterFailure("Could not open service diagnostics.") }
      return Archive(schemaVersion: 1, entries: [])
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == getuid(), info.st_nlink == 1, info.st_size <= Self.maximumBytes,
      let data = try handle.read(upToCount: Self.maximumBytes + 1),
      data.count <= Self.maximumBytes
    else { throw RouterFailure("Service diagnostics must be a bounded, owned regular file.") }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let archive = try decoder.decode(Archive.self, from: data)
    guard archive.schemaVersion == 1, archive.entries.count <= Self.maximumEntries else {
      throw RouterFailure("Unsupported service diagnostic archive.")
    }
    return archive
  }
}
