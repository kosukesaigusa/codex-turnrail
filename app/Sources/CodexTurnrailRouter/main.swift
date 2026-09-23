import CodexTurnrailCore
import Darwin
import Foundation

do {
  let status = try OfficialEngineRouter.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    environment: ProcessInfo.processInfo.environment,
    executable: URL(filePath: CommandLine.arguments[0]).standardizedFileURL
  )
  exit(status)
} catch {
  let message = "Codex Turnrail could not start: \(error.localizedDescription)\n"
  try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
  exit(1)
}
