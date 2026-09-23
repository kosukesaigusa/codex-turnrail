import Foundation

public struct LaunchCommand: Equatable, Sendable {
  public let executableURL: URL
  public let arguments: [String]

  public init(executableURL: URL, arguments: [String]) {
    self.executableURL = executableURL
    self.arguments = arguments
  }
}

public enum LaunchCommandFactory {
  public static func makeCodexTurnrailLaunch(
    appURL: URL,
    routerURL: URL,
    turnrailRootURL: URL
  ) -> LaunchCommand {
    LaunchCommand(
      executableURL: URL(filePath: "/usr/bin/open"),
      arguments: [
        "-n",
        "--env",
        "CODEX_CLI_PATH=\(routerURL.path)",
        "--env",
        "CODEX_APP_SERVER_FORCE_CLI=1",
        "--env",
        "CODEX_TURNRAIL_APP=\(appURL.path)",
        "--env",
        "CODEX_TURNRAIL_ROOT=\(turnrailRootURL.path)",
        appURL.path,
      ]
    )
  }
}
