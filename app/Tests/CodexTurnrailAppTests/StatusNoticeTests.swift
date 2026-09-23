import CodexTurnrailCore
import Foundation
import Testing

@testable import CodexTurnrailApp

struct StatusNoticeTests {
  @Test
  func aMatchDescribesTheReleaseReferenceAndOffersReleases() {
    let notice = StatusNotice.compatibility(referenceCompatibilityReport())
    #expect(notice.title == "ChatGPT Version")
    #expect(notice.message.contains("matches the reference"))
    #expect(notice.recovery == .releases)
    #expect(notice.recovery?.title == "See releases")
  }

  @Test
  func aDifferentVersionExplainsThatTurnrailCanStillBeUsed() {
    let reference = CodexCompatibilityContract.reference
    let installed = CodexInstallation(
      bundleIdentifier: reference.bundleIdentifier, appVersion: "99.1", appBuild: "9999",
      cliVersion: "codex-cli 99.2.0")
    let report = CompatibilityReport(installed: installed, engineVersion: installed.cliVersion)
    let notice = StatusNotice.compatibility(report)
    #expect(notice.title == "ChatGPT Version")
    #expect(notice.message.contains("99.1 (9999)"))
    #expect(notice.message.contains("codex-cli 99.2.0"))
    #expect(notice.message.contains("\(reference.appVersion) (\(reference.appBuild))"))
    #expect(notice.message.contains("You can still use Turnrail"))
    #expect(notice.recovery == .releases)
    #expect(
      notice.recovery?.url.absoluteString
        == "https://github.com/kosukesaigusa/codex-turnrail/releases")
  }

  @Test
  func anEngineThatDoesNotBelongToChatGPTIsAnInstallationError() {
    let report = CompatibilityReport(
      installed: referenceCompatibilityReport().installed, engineVersion: "codex-cli 0")
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
      RouterPathResolverError.routerIsNotExecutable("/test/router"))
    #expect(broken.title == "Reinstall Turnrail")
    #expect(broken.recovery == .releases)
    for error in [
      CompatibilityProbeError.invalidInfoPlist("CFBundleVersion"),
      .engineUnavailable("/test/engine"),
    ] {
      let notice = StatusNotice.compatibilityError(error)
      #expect(notice.title == "Reinstall ChatGPT")
      #expect(notice.recovery == .installation)
    }
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
