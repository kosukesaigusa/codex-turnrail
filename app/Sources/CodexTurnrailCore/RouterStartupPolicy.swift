import Foundation

/// Admit official startup configuration commands and dedicated policy RPC connections.
///
/// These entry points reach the official Engine before account routing starts.
/// They permit policy/configuration reads and the desktop's explicit sign-out flow, never tasks
/// or inference. Command arguments and initialization envelopes follow the desktop protocol.
enum RouterStartupPolicy {
  /// Admit only the one-shot policy command; the official Engine validates its values.
  static func validateCommand(_ options: [String]) throws {
    let valued = ["-c", "--config", "--enable", "--disable", "--startup-client-info"]
    let switches = ["--analytics-default-enabled", "--strict-config", "--startup-sign-out"]
    var index = 0
    var printConfiguration = false
    while index < options.count {
      let option = options[index]
      if option == "--print-startup-config" {
        printConfiguration = true
        index += 1
      } else if valued.contains(option) {
        guard index + 1 < options.count, !options[index + 1].hasPrefix("-") else {
          throw RouterFailure("Missing official startup option value.")
        }
        index += 2
      } else if valued.filter({ $0.hasPrefix("--") }).contains(where: { option.hasPrefix($0 + "=") }
      ) {
        guard !option.hasSuffix("=") else {
          throw RouterFailure("Missing official startup option value.")
        }
        index += 1
      } else if switches.contains(option) {
        index += 1
      } else {
        throw RouterFailure("The startup command only supports organization policy checks.")
      }
    }
    guard printConfiguration else {
      throw RouterFailure("The startup command must print the official configuration.")
    }
  }

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
    case "configRequirements/read", "config/read", "account/logout":
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
