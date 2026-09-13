import Foundation
import Testing

@testable import CodexTurnrailCore

struct CommandExecutorTests {
  @Test
  func runsWithExactlyTheSuppliedEnvironment() throws {
    let result = try CommandExecutor.live.execute(
      URL(filePath: "/usr/bin/env"),
      arguments: [],
      environment: ["TURNRAIL_TEST_ENV": "explicit"]
    )

    #expect(result.exitCode == 0)
    let environmentWasExact = result.standardOutput == "TURNRAIL_TEST_ENV=explicit\n"
    #expect(environmentWasExact)
    #expect(result.standardError.isEmpty)
  }
}
