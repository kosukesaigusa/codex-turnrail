import Darwin
import Foundation
import Security

/// The signed native Computer Use service starts its own policy/authentication CLI.
///
/// It inherits the desktop's CLI override, but must not own a second routing ledger.
/// Identify the running caller by its OpenAI signature, then preserve its official
/// protocol and configuration unchanged. This does not grant Computer Use access.
enum RouterHelperProcess {
  static func isComputerUseService(processID: pid_t) throws -> Bool {
    var code: SecCode?
    let status = SecCodeCopyGuestWithAttributes(
      nil, [kSecGuestAttributePid: processID] as CFDictionary, SecCSFlags(), &code)
    guard status == errSecSuccess, let code else {
      throw RouterFailure("Could not verify the Engine caller's code identity.")
    }
    var requirement: SecRequirement?
    let expression =
      "anchor apple generic and identifier \"com.openai.sky.CUAService\""
      + " and certificate leaf[subject.OU] = \"2DC432GLL2\""
    guard
      SecRequirementCreateWithString(expression as CFString, SecCSFlags(), &requirement)
        == errSecSuccess, let requirement
    else { throw RouterFailure("Could not prepare the Computer Use caller requirement.") }
    let validation = SecCodeCheckValidity(code, SecCSFlags(), requirement)
    if validation == errSecCSReqFailed || validation == errSecCSUnsigned { return false }
    guard validation == errSecSuccess else {
      throw RouterFailure("The Engine caller has an invalid code signature.")
    }
    return true
  }

  static func environment(_ environment: [String: String], engine: URL) -> [String: String] {
    var result = environment
    result["CODEX_CLI_PATH"] = engine.path
    result.removeValue(forKey: "CODEX_TURNRAIL_APP")
    result.removeValue(forKey: "CODEX_TURNRAIL_ROOT")
    return result
  }

  /// Preserve stdio, process identity, signals, and exit status with no extra RPC layer.
  static func replace(engine: URL, arguments: [String], environment: [String: String]) throws
    -> Never
  {
    let argv = ([engine.path] + arguments).map { strdup($0) } + [nil]
    let envp =
      self.environment(environment, engine: engine).map { strdup($0.key + "=" + $0.value) }
      + [nil]
    defer {
      for value in argv { free(value) }
      for value in envp { free(value) }
    }
    argv.withUnsafeBufferPointer { argv in
      envp.withUnsafeBufferPointer { envp in
        _ = execve(engine.path, argv.baseAddress!, envp.baseAddress!)
      }
    }
    throw RouterFailure("Could not start the official Computer Use helper Engine (\(errno)).")
  }
}
