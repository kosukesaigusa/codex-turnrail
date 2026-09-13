import Foundation
import Testing

@testable import CodexTurnrailCore

struct CompatibilityTests {
  @Test
  func acceptsTheExactSupportedContract() {
    let contract = CodexCompatibilityContract.supported
    let installed = CodexInstallation(
      bundleIdentifier: contract.bundleIdentifier,
      appVersion: contract.appVersion,
      appBuild: contract.appBuild,
      cliVersion: contract.cliVersion
    )

    let mismatches = CompatibilityEvaluator.evaluate(
      contract: contract,
      installed: installed,
      engineVersion: contract.cliVersion
    )

    #expect(mismatches == [])
  }

  @Test
  func reportsEveryCompatibilityMismatch() {
    let installed = CodexInstallation(
      bundleIdentifier: "example.invalid",
      appVersion: "0",
      appBuild: "1",
      cliVersion: "codex-cli 0"
    )

    let mismatches = CompatibilityEvaluator.evaluate(
      contract: .supported,
      installed: installed,
      engineVersion: "codex-cli 1"
    )

    #expect(mismatches.count == 5)
  }
}
