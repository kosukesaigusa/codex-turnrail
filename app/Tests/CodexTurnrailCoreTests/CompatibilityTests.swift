import Foundation
import Testing

@testable import CodexTurnrailCore

struct CompatibilityTests {
  let reference = CodexCompatibilityContract.reference

  @Test
  func theReleaseReferenceMatchesAndCanLaunch() {
    let report = report()
    #expect(report.matchesReference)
    #expect(report.canLaunch)
  }

  @Test(arguments: ["app", "build", "engine", "all"])
  func differentVersionsCanLaunchWithoutClaimingAReferenceMatch(field: String) {
    let report = report(
      appVersion: ["app", "all"].contains(field) ? "99.1" : reference.appVersion,
      appBuild: ["build", "all"].contains(field) ? "99999" : reference.appBuild,
      cliVersion: ["engine", "all"].contains(field) ? "codex-cli 99.1.0" : reference.cliVersion)
    #expect(!report.matchesReference)
    #expect(report.canLaunch)
    #expect(report.launchIssues.isEmpty)
  }

  @Test
  func otherApplicationsCannotLaunchEvenWithMatchingVersions() {
    let report = report(bundleIdentifier: "example.invalid")
    #expect(!report.matchesReference)
    #expect(!report.canLaunch)
    #expect(report.launchIssues.count == 1)
  }

  @Test
  func anEngineOutsideTheInstalledBundleIsStillRejected() {
    let report = report(engineVersion: "codex-cli 0.0.1")
    #expect(!report.matchesReference)
    #expect(!report.canLaunch)
    #expect(report.launchIssues.count == 1)
  }

  @Test
  func modelRequestsIdentifyTheInstalledEngineRatherThanTheReleaseReference() throws {
    let url = try RouterAccounts.modelCatalogURL(engineVersion: "codex-cli 99.2.0-alpha.7")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "chatgpt.com")
    #expect(components.path == "/backend-api/codex/models")
    #expect(
      components.queryItems == [URLQueryItem(name: "client_version", value: "99.2.0-alpha.7")])
  }

  @Test(arguments: ["", "codex-cli ", "codex-cli unknown", "other-cli 1.0", "codex-cli 1.0\nextra"])
  func unknownEngineVersionsCannotBeReplacedWithTheReference(version: String) {
    #expect(throws: (any Error).self) {
      try RouterAccounts.modelCatalogURL(engineVersion: version)
    }
  }

  private func report(
    bundleIdentifier: String? = nil, appVersion: String? = nil, appBuild: String? = nil,
    cliVersion: String? = nil, engineVersion: String? = nil
  ) -> CompatibilityReport {
    // Omitted fixture fields explicitly represent the release reference.
    let installed = CodexInstallation(
      bundleIdentifier: bundleIdentifier ?? reference.bundleIdentifier,
      appVersion: appVersion ?? reference.appVersion, appBuild: appBuild ?? reference.appBuild,
      cliVersion: cliVersion ?? reference.cliVersion)
    return CompatibilityReport(
      installed: installed, engineVersion: engineVersion ?? installed.cliVersion)
  }
}
