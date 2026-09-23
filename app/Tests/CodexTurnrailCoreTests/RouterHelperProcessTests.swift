import Darwin
import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterHelperProcessTests {
  @Test
  func anUnrelatedCallerCannotClaimTheOfficialNativeServiceIdentity() throws {
    #expect(try !RouterHelperProcess.isComputerUseService(processID: getpid()))
    #expect(throws: RouterFailure.self) {
      try RouterHelperProcess.isComputerUseService(processID: -1)
    }
  }

  @Test
  func officialHelpersKeepTheOriginalHomeAndPolicyEnvironment() {
    let input = [
      "CODEX_HOME": "/test/desktop-home", "CODEX_CLI_PATH": "/test/router",
      "CODEX_TURNRAIL_APP": "/test/ChatGPT.app", "CODEX_TURNRAIL_ROOT": "/test/accounts",
      "SKY_CUA_SERVICE_PATH": "/test/service", "NODE_REPL_FORCE_STRICT_AUTO_REVIEW": "1",
    ]
    let output = RouterHelperProcess.environment(input, engine: URL(filePath: "/test/official"))
    #expect(output["CODEX_CLI_PATH"] == "/test/official")
    #expect(output["CODEX_TURNRAIL_APP"] == nil)
    #expect(output["CODEX_TURNRAIL_ROOT"] == nil)
    for key in ["CODEX_HOME", "SKY_CUA_SERVICE_PATH", "NODE_REPL_FORCE_STRICT_AUTO_REVIEW"] {
      #expect(output[key] == input[key])
    }
  }

  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_COMPUTER_USE_PID"] != nil)
  )
  func recognizesTheRunningOfficialNativeService() throws {
    let value = try #require(
      ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_COMPUTER_USE_PID"])
    let pid = try #require(pid_t(value))
    #expect(try RouterHelperProcess.isComputerUseService(processID: pid))
  }
}
