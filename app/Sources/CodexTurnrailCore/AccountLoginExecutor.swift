import Darwin
import Foundation

public struct AccountLoginExecutor: Sendable {
  private let run: @Sendable (AccountAuthenticationCommand) async throws -> CommandResult

  public init(
    run: @escaping @Sendable (AccountAuthenticationCommand) async throws -> CommandResult
  ) {
    self.run = run
  }

  public func execute(_ command: AccountAuthenticationCommand) async throws -> CommandResult {
    try Task.checkCancellation()
    return try await run(command)
  }

  public static let live = AccountLoginExecutor { command in
    let operation = CancellableLoginProcess()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        // Process and pipe waits need threads outside Swift's cooperative executor.
        DispatchQueue(label: "CodexTurnrail.AccountLogin.process").async {
          continuation.resume(with: Result { try operation.run(command) })
        }
      }
    } onCancel: {
      operation.cancel()
    }
  }
}

// The lock protects cancellation and process lifetime across the worker and cancellation handler.
private final class CancellableLoginProcess: @unchecked Sendable {
  private let process = Process()
  private let lock = NSLock()
  private var cancelled = false
  private var running = false
  private var errorData = Data()

  func run(_ command: AccountAuthenticationCommand) throws -> CommandResult {
    let output = Pipe()
    let error = Pipe()
    process.executableURL = command.executableURL
    process.arguments = command.arguments
    process.environment = command.environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = error

    try lock.withLock {
      guard !cancelled else { throw CancellationError() }
      try process.run()
      running = true
    }

    let errorRead = DispatchGroup()
    errorRead.enter()
    DispatchQueue(label: "CodexTurnrail.AccountLogin.stderr").async {
      let data = error.fileHandleForReading.readDataToEndOfFile()
      self.lock.withLock { self.errorData = data }
      errorRead.leave()
    }
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    errorRead.wait()

    return try lock.withLock {
      running = false
      guard !cancelled else { throw CancellationError() }
      return CommandResult(
        exitCode: process.terminationStatus,
        standardOutput: String(decoding: outputData, as: UTF8.self),
        standardError: String(decoding: errorData, as: UTF8.self)
      )
    }
  }

  func cancel() {
    lock.withLock {
      cancelled = true
      if running && process.isRunning { process.terminate() }
    }
    // Bound cancellation even if this login process ignores SIGTERM.
    DispatchQueue(label: "CodexTurnrail.AccountLogin.cancellation").asyncAfter(deadline: .now() + 2)
    {
      [weak self] in
      guard let self else { return }
      self.lock.withLock {
        if self.running && self.process.isRunning {
          kill(self.process.processIdentifier, SIGKILL)
        }
      }
    }
  }
}
