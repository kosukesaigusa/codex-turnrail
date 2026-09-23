import CodexTurnrailCore
import Foundation
import Testing

@testable import CodexTurnrailApp

struct StatusNoticeTests {
  @Test
  func successReportsOnlyCompatibility() {
    let notice = StatusNotice.compatibility(supportedCompatibilityReport())
    #expect(notice.title == "Compatible")
    #expect(notice.message == "This version of the ChatGPT app is supported.")
    #expect(notice.recovery == nil)
  }

  @Test
  func anUnsupportedVersionShowsInstalledAndSupportedVersionsAndReleases() {
    let contract = CodexCompatibilityContract.supported
    let installed = CodexInstallation(
      bundleIdentifier: contract.bundleIdentifier, appVersion: "99.1", appBuild: "9999",
      cliVersion: contract.cliVersion
    )
    let report = CompatibilityReport(
      installed: installed, engineVersion: contract.cliVersion,
      mismatches: CompatibilityEvaluator.evaluate(
        contract: contract, installed: installed, engineVersion: contract.cliVersion
      )
    )
    #expect(!report.isCompatible)
    let notice = StatusNotice.compatibility(report)
    #expect(notice.title == "Unsupported ChatGPT Version")
    #expect(notice.message.contains("99.1 (9999)"))
    #expect(notice.message.contains("\(contract.appVersion) (\(contract.appBuild))"))
    #expect(notice.recovery == .releases)
    #expect(
      notice.recovery?.url.absoluteString
        == "https://github.com/kosukesaigusa/codex-turnrail/releases")
  }

  @Test
  func aWrongEngineRequiresReinstallingTurnrail() {
    let supported = supportedCompatibilityReport()
    let report = CompatibilityReport(
      installed: supported.installed, engineVersion: "codex-cli 0",
      mismatches: ["ChatGPT Engine codex-cli 0 does not match the supported CLI."]
    )
    let notice = StatusNotice.compatibility(report)
    #expect(notice.title == "Reinstall Turnrail")
    #expect(notice.recovery == .releases)
  }

  @Test
  func aWrongBundledCLIIsNotReportedAsCompatible() {
    let contract = CodexCompatibilityContract.supported
    let installed = CodexInstallation(
      bundleIdentifier: contract.bundleIdentifier,
      appVersion: contract.appVersion, appBuild: contract.appBuild, cliVersion: "codex-cli 0"
    )
    let report = CompatibilityReport(
      installed: installed, engineVersion: contract.cliVersion,
      mismatches: CompatibilityEvaluator.evaluate(
        contract: contract, installed: installed, engineVersion: contract.cliVersion
      )
    )
    #expect(!report.isCompatible)
    let notice = StatusNotice.compatibility(report)
    #expect(notice.title == "Reinstall ChatGPT")
    #expect(notice.recovery == .installation)
  }

  @Test
  func missingAppsAndBrokenPackagesHaveDifferentRecoveryDestinations() {
    let missing = StatusNotice.compatibilityError(
      CompatibilityProbeError.appBundleMissing("/Applications/ChatGPT.app"))
    #expect(missing.title == "ChatGPT Not Found")
    #expect(missing.message.contains("/Applications/ChatGPT.app"))
    #expect(missing.recovery == .installation)
    let broken = StatusNotice.compatibilityError(
      CompatibilityProbeError.engineUnavailable("/test/engine"))
    #expect(broken.title == "Reinstall Turnrail")
    #expect(broken.recovery == .releases)
    let corrupt = StatusNotice.compatibilityError(
      CompatibilityProbeError.invalidInfoPlist("CFBundleVersion"))
    #expect(corrupt.title == "Reinstall ChatGPT")
    #expect(corrupt.recovery == .installation)
  }

  @Test
  func unexpectedProbeFailuresRemainExplicit() {
    let error = CompatibilityProbeError.commandFailed(
      executable: "/test/engine", exitCode: 1, message: "Test failure")
    let notice = StatusNotice.compatibilityError(error)
    #expect(notice.title == "Compatibility Check Failed")
    #expect(notice.message.contains("Test failure"))
    #expect(notice.recovery == nil)
  }
}
