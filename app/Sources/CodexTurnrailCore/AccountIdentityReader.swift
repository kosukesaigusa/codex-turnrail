import Foundation

public enum AccountRecoveryAction: Equatable, Sendable {
  case reauthenticate
}

public struct AccountServerFailure: Equatable, Sendable {
  public let message: String
  public let diagnosticJSON: String
  public let recoveryAction: AccountRecoveryAction?

  public init(
    message: String,
    diagnosticJSON: String,
    recoveryAction: AccountRecoveryAction?
  ) {
    self.message = message
    self.diagnosticJSON = diagnosticJSON
    self.recoveryAction = recoveryAction
  }
}

public enum AccountReaderError: LocalizedError, Equatable {
  case timedOut
  case engineExited(Int32, String)
  case invalidResponse
  case serverError(AccountServerFailure)
  case unsupportedAccountType(String)
  case missingEmail
  case unsupportedPlan(String)
  case invalidUsage(String)

  public var errorDescription: String? {
    switch self {
    case .timedOut:
      "Timed out while reading the ChatGPT account."
    case .engineExited(let status, let message):
      "ChatGPT Engine exited with status \(status): \(message)"
    case .invalidResponse:
      "ChatGPT Engine returned an invalid account response."
    case .serverError(let failure):
      "ChatGPT Engine could not read the ChatGPT account: \(failure.message)"
    case .unsupportedAccountType(let type):
      "ChatGPT Engine returned unsupported account type \(type)."
    case .missingEmail:
      "ChatGPT did not return an email address for this account."
    case .unsupportedPlan(let plan):
      "ChatGPT Engine returned unsupported plan type \(plan)."
    case .invalidUsage(let message):
      "ChatGPT Engine returned invalid usage data: \(message)"
    }
  }
}

public struct AccountIdentityReader: Sendable {
  private let readIdentity: @Sendable (URL, URL) async throws -> ChatGPTAccountIdentity?

  public init(
    readIdentity: @escaping @Sendable (URL, URL) async throws -> ChatGPTAccountIdentity?
  ) {
    self.readIdentity = readIdentity
  }

  public func read(
    engineURL: URL,
    authHomeURL: URL
  ) async throws -> ChatGPTAccountIdentity? {
    try await readIdentity(engineURL, authHomeURL)
  }

  public static let live = AccountIdentityReader { engineURL, authHomeURL in
    try await Task.detached {
      let line = try AccountAppServerTransport.request(
        engineURL: engineURL,
        authHomeURL: authHomeURL,
        request: AccountIdentityProtocol.accountReadRequest,
        responseID: 2
      )
      return try AccountIdentityProtocol.parseAccountReadResponse(line)
    }.value
  }
}

enum AccountIdentityProtocol {
  static let initializeRequest =
    #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-turnrail","title":"Codex Turnrail","version":"0.5.0"}}}"#
  static let initializedNotification = #"{"method":"initialized"}"#
  static let accountReadRequest =
    #"{"id":2,"method":"account/read","params":{"refreshToken":false}}"#

  static func responseID(from line: String) throws -> Int? {
    let object = try jsonObject(from: line)
    return (object["id"] as? NSNumber)?.intValue
  }

  static func parseAccountReadResponse(_ line: String) throws -> ChatGPTAccountIdentity? {
    let object = try jsonObject(from: line)
    guard (object["id"] as? NSNumber)?.intValue == 2 else {
      throw AccountReaderError.invalidResponse
    }
    if let error = object["error"] as? [String: Any] {
      throw AccountReaderError.serverError(
        try AccountServerFailureParser.parse(response: object, error: error)
      )
    }
    guard let result = object["result"] as? [String: Any] else {
      throw AccountReaderError.invalidResponse
    }
    guard let accountValue = result["account"] else {
      throw AccountReaderError.invalidResponse
    }
    if accountValue is NSNull {
      return nil
    }
    guard let account = accountValue as? [String: Any] else {
      throw AccountReaderError.invalidResponse
    }
    guard let type = account["type"] as? String else {
      throw AccountReaderError.invalidResponse
    }
    guard type == "chatgpt" else {
      throw AccountReaderError.unsupportedAccountType(type)
    }
    guard let email = account["email"] as? String else {
      throw AccountReaderError.missingEmail
    }
    guard let rawPlan = account["planType"] as? String else {
      throw AccountReaderError.invalidResponse
    }
    guard let plan = ChatGPTPlan(rawValue: rawPlan) else {
      throw AccountReaderError.unsupportedPlan(rawPlan)
    }
    return try ChatGPTAccountIdentity(email: email, planType: plan)
  }

  private static func jsonObject(from line: String) throws -> [String: Any] {
    guard let data = line.data(using: .utf8),
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw AccountReaderError.invalidResponse
    }
    return object
  }
}

enum AccountServerFailureParser {
  static func parse(
    response: [String: Any],
    error: [String: Any]
  ) throws -> AccountServerFailure {
    guard let message = error["message"] as? String,
      JSONSerialization.isValidJSONObject(response),
      let diagnosticData = try? JSONSerialization.data(
        withJSONObject: response,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      )
    else {
      throw AccountReaderError.invalidResponse
    }

    return AccountServerFailure(
      message: message,
      diagnosticJSON: String(decoding: diagnosticData, as: UTF8.self),
      recoveryAction: containsExpiredTokenCode(in: error)
        || embeddedBodyContainsExpiredTokenCode(message)
        ? .reauthenticate
        : nil
    )
  }

  private static func embeddedBodyContainsExpiredTokenCode(_ message: String) -> Bool {
    guard let bodyMarker = message.range(of: "; body=") else {
      return false
    }
    let body = String(message[bodyMarker.upperBound...])
    guard let data = body.data(using: .utf8),
      let value = try? JSONSerialization.jsonObject(with: data)
    else {
      return false
    }
    return containsExpiredTokenCode(in: value)
  }

  private static func containsExpiredTokenCode(in value: Any) -> Bool {
    if let object = value as? [String: Any] {
      if let code = object["code"] as? String,
        [
          "token_expired", "token_revoked", "refresh_token_reused", "refresh_token_expired",
          "refresh_token_invalidated",
        ].contains(code)
      {
        return true
      }
      return object.values.contains { containsExpiredTokenCode(in: $0) }
    }
    if let array = value as? [Any] {
      return array.contains { containsExpiredTokenCode(in: $0) }
    }
    return false
  }
}

enum AccountAppServerTransport {
  static func request(
    engineURL: URL,
    authHomeURL: URL,
    request: String,
    responseID: Int
  ) throws -> String {
    try AccountCredentialStore.withExclusiveAccess(to: authHomeURL) {
      try lockedRequest(
        engineURL: engineURL, authHomeURL: authHomeURL, request: request, responseID: responseID)
    }
  }

  private static func lockedRequest(
    engineURL: URL, authHomeURL: URL, request: String, responseID: Int
  ) throws -> String {
    let process = ManagedAccountReadProcess()
    let standardInput = Pipe()
    let standardOutput = Pipe()
    let standardError = Pipe()

    process.process.executableURL = engineURL
    process.process.arguments = [
      "app-server",
      "--listen",
      "stdio://",
      "--config",
      "cli_auth_credentials_store=\"keyring\"",
    ]
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = authHomeURL.path
    environment.removeValue(forKey: "CODEX_TURNRAIL_ROOT")
    process.process.environment = environment
    process.process.standardInput = standardInput
    process.process.standardOutput = standardOutput
    process.process.standardError = standardError

    try process.process.run()
    process.scheduleTimeout(after: 15)
    defer {
      process.finish()
    }

    try write(AccountIdentityProtocol.initializeRequest, to: standardInput.fileHandleForWriting)
    _ = try waitForResponse(id: 1, from: standardOutput.fileHandleForReading, process: process)
    try write(
      AccountIdentityProtocol.initializedNotification, to: standardInput.fileHandleForWriting)
    try write(request, to: standardInput.fileHandleForWriting)
    return try waitForResponse(
      id: responseID,
      from: standardOutput.fileHandleForReading,
      process: process
    )
  }

  private static func write(_ line: String, to handle: FileHandle) throws {
    guard let data = (line + "\n").data(using: .utf8) else {
      throw AccountReaderError.invalidResponse
    }
    try handle.write(contentsOf: data)
  }

  private static func waitForResponse(
    id: Int,
    from handle: FileHandle,
    process: ManagedAccountReadProcess
  ) throws -> String {
    while let line = try readLine(from: handle) {
      if try AccountIdentityProtocol.responseID(from: line) == id {
        return line
      }
    }
    if process.didTimeOut {
      throw AccountReaderError.timedOut
    }
    let errorData = process.standardErrorData()
    let message = String(decoding: errorData, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    throw AccountReaderError.engineExited(process.process.terminationStatus, message)
  }

  private static func readLine(from handle: FileHandle) throws -> String? {
    var data = Data()
    while let byte = try handle.read(upToCount: 1), !byte.isEmpty {
      if byte[byte.startIndex] == 0x0A {
        return String(decoding: data, as: UTF8.self)
      }
      data.append(byte)
    }
    return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
  }
}

private final class ManagedAccountReadProcess: @unchecked Sendable {
  let process = Process()

  private let lock = NSLock()
  private var timeoutWorkItem: DispatchWorkItem?
  private var timedOut = false
  private weak var standardErrorHandle: FileHandle?

  var didTimeOut: Bool {
    lock.withLock { timedOut }
  }

  func scheduleTimeout(after seconds: TimeInterval) {
    if let pipe = process.standardError as? Pipe {
      standardErrorHandle = pipe.fileHandleForReading
    }
    let workItem = DispatchWorkItem { [weak self] in
      self?.terminateForTimeout()
    }
    lock.withLock {
      timeoutWorkItem = workItem
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: workItem)
  }

  func standardErrorData() -> Data {
    standardErrorHandle?.readDataToEndOfFile() ?? Data()
  }

  func finish() {
    let workItem = lock.withLock { () -> DispatchWorkItem? in
      let current = timeoutWorkItem
      timeoutWorkItem = nil
      return current
    }
    workItem?.cancel()
    if let standardInput = process.standardInput as? Pipe {
      try? standardInput.fileHandleForWriting.close()
    }
    if process.isRunning {
      process.terminate()
    }
    process.waitUntilExit()
  }

  private func terminateForTimeout() {
    lock.withLock {
      timedOut = true
    }
    if process.isRunning {
      process.terminate()
    }
  }
}
