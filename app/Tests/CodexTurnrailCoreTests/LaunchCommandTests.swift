import Foundation
import Testing

@testable import CodexTurnrailCore

struct LaunchCommandTests {
  @Test
  func createsTheSingleSupportedLaunchPath() {
    let appURL = URL(filePath: "/Applications/ChatGPT.app")
    let routerURL = URL(filePath: "/private/engine/codex")
    let turnrailRootURL = URL(filePath: "/private/turnrail")

    let command = LaunchCommandFactory.makeCodexTurnrailLaunch(
      appURL: appURL,
      routerURL: routerURL,
      turnrailRootURL: turnrailRootURL
    )

    #expect(
      command
        == LaunchCommand(
          executableURL: URL(filePath: "/usr/bin/open"),
          arguments: [
            "-n",
            "--env",
            "CODEX_CLI_PATH=/private/engine/codex",
            "--env",
            "CODEX_APP_SERVER_FORCE_CLI=1",
            "--env",
            "CODEX_TURNRAIL_APP=/Applications/ChatGPT.app",
            "--env",
            "CODEX_TURNRAIL_ROOT=/private/turnrail",
            "/Applications/ChatGPT.app",
          ]
        ))
  }
}
