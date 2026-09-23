import CryptoKit
import Darwin
import Foundation

struct RouterFailure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

enum RouterJSON {
  static func object(_ data: Data) throws -> [String: Any] {
    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw RouterFailure("Expected a JSON object.")
    }
    return result
  }

  static func data(_ value: Any) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
  }

  static func string(_ value: Any) throws -> String {
    String(decoding: try data(value), as: UTF8.self)
  }

  static func text(_ object: [String: Any], _ key: String) throws -> String {
    guard let value = object[key] as? String, !value.isEmpty else {
      throw RouterFailure("Missing or invalid \(key).")
    }
    return value
  }

  static func map(_ object: [String: Any], _ key: String) throws -> [String: Any] {
    guard let value = object[key] as? [String: Any] else {
      throw RouterFailure("Missing or invalid \(key).")
    }
    return value
  }

  static func array(_ object: [String: Any], _ key: String) throws -> [[String: Any]] {
    guard let value = object[key] as? [[String: Any]] else {
      throw RouterFailure("Missing or invalid \(key).")
    }
    return value
  }

  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func quote(_ value: String) -> String {
    // A JSON string is also a TOML basic string for the paths and ASCII keys used here.
    String(
      decoding: try! JSONSerialization.data(
        withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]),
      as: UTF8.self)
  }

  static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  static func privateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
    guard values.isSymbolicLink == false, values.isDirectory == true else {
      throw RouterFailure("Runtime storage must be a real directory.")
    }
    guard chmod(url.path, 0o700) == 0 else {
      throw RouterFailure("Could not protect runtime storage.")
    }
  }

  static func writePrivate(_ data: Data, to url: URL) throws {
    let temporary = url.deletingLastPathComponent().appending(
      path: ".turnrail-" + UUID().uuidString)
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw RouterFailure("Could not create private runtime data.") }
    defer {
      Darwin.close(descriptor)
      unlink(temporary.path)
    }
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeBytes {
        Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset)
      }
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { throw RouterFailure("Could not write private runtime data.") }
      offset += count
    }
    guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else {
      throw RouterFailure("Could not commit private runtime data.")
    }
    let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_NOFOLLOW)
    guard parent >= 0 else { throw RouterFailure("Could not synchronize runtime storage.") }
    defer { Darwin.close(parent) }
    guard fsync(parent) == 0 else { throw RouterFailure("Could not synchronize runtime storage.") }
  }
}

/// Immutable JSON values cross worker queues only through this wrapper.
final class RouterObject: @unchecked Sendable {
  let value: [String: Any]
  init(_ value: [String: Any]) { self.value = value }
}
