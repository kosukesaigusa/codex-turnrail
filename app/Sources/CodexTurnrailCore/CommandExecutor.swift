import Foundation

public struct CommandResult: Equatable, Sendable {
  public let exitCode: Int32
  public let standardOutput: String
  public let standardError: String

  public init(exitCode: Int32, standardOutput: String, standardError: String) {
    self.exitCode = exitCode
    self.standardOutput = standardOutput
    self.standardError = standardError
  }
}

public struct CommandExecutor: Sendable {
  private let executeCommand: @Sendable (URL, [String], [String: String]) throws -> CommandResult

  public init(
    executeCommand: @escaping @Sendable (URL, [String], [String: String]) throws -> CommandResult
  ) {
    self.executeCommand = executeCommand
  }

  public func execute(
    _ executableURL: URL,
    arguments: [String],
    environment: [String: String]
  ) throws -> CommandResult {
    try executeCommand(executableURL, arguments, environment)
  }

  public static let live = CommandExecutor { executableURL, arguments, environment in
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()

    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    process.standardOutput = standardOutput
    process.standardError = standardError

    try process.run()
    process.waitUntilExit()

    let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let errorData = standardError.fileHandleForReading.readDataToEndOfFile()

    return CommandResult(
      exitCode: process.terminationStatus,
      standardOutput: String(decoding: outputData, as: UTF8.self),
      standardError: String(decoding: errorData, as: UTF8.self)
    )
  }
}
