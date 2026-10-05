import Foundation
import Testing

@testable import CodexTurnrailCore

struct LaunchCommandTests {
  @Test
  func routesChatRequestsAndUsesTheOfficialEngineForLocalCloudExecution() {
    let appURL = URL(filePath: "/Applications/ChatGPT.app")
    let routerURL = URL(filePath: "/private/engine/codex")
    let engineURL = URL(
      filePath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
    let turnrailRootURL = URL(filePath: "/private/turnrail")

    let command = LaunchCommandFactory.makeCodexTurnrailLaunch(
      appURL: appURL,
      routerURL: routerURL,
      engineURL: engineURL,
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
            "CODEX_TPP_LOCAL_EXECUTOR_CLI_PATH=/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "--env",
            "CODEX_TURNRAIL_APP=/Applications/ChatGPT.app",
            "--env",
            "CODEX_TURNRAIL_ROOT=/private/turnrail",
            "/Applications/ChatGPT.app",
          ]
        ))
  }
}
