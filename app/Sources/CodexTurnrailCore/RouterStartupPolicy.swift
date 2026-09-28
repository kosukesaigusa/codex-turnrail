import Foundation

/// The desktop uses a dedicated connection to load organization requirements.
///
/// This connection must reach the official Engine before account routing starts.
/// It permits policy reads and the desktop's explicit sign-out flow, never tasks
/// or inference. The initialization envelope comes from the desktop protocol.
enum RouterStartupPolicy {
  static func isInitialization(_ message: [String: Any]) -> Bool {
    guard message["method"] as? String == "initialize",
      message["id"] as? String == "network-initialize",
      let params = message["params"] as? [String: Any],
      let client = params["clientInfo"] as? [String: Any]
    else { return false }
    return client["name"] as? String == "codex_desktop"
  }

  static func validate(_ message: [String: Any]) throws {
    switch message["method"] as? String {
    case "initialize" where isInitialization(message): return
    case "initialized" where message["id"] == nil: return
    case "configRequirements/read", "account/logout":
      guard message["id"] != nil else { break }
      return
    default: break
    }
    throw RouterFailure("The desktop startup connection only supports organization policy checks.")
  }
}

/// Read initialization once, then transfer exclusive ownership to the input queue.
///
/// The reader is never accessed concurrently. Retain its buffered bytes so a client
/// that writes several protocol messages at once does not lose subsequent messages.
final class RouterEngineInput: @unchecked Sendable {
  let policyOnly: Bool
  private let reader: EngineLineReader
  private var first: Data?

  init(_ handle: FileHandle) throws {
    reader = EngineLineReader(handle)
    first = try reader.next()
    if let first {
      policyOnly = RouterStartupPolicy.isInitialization(try RouterJSON.object(first))
    } else {
      policyOnly = false
    }
  }

  var hasInitialization: Bool { first != nil }

  func next() throws -> Data? {
    if let value = first {
      first = nil
      return value
    }
    return try reader.next()
  }
}
