import CodexTurnrailCore
import Foundation

struct StatusNotice: Equatable, Identifiable {
  enum Recovery: Equatable {
    case releases
    case installation

    var title: String {
      switch self {
      case .releases: "See releases"
      case .installation: "Installation Guide"
      }
    }

    var url: URL {
      switch self {
      case .releases:
        URL(string: "https://github.com/kosukesaigusa/codex-turnrail/releases")!
      case .installation:
        URL(string: "https://github.com/kosukesaigusa/codex-turnrail#install")!
      }
    }
  }

  let title: String
  let message: String
  let recovery: Recovery?

  var id: String { "\(title):\(message)" }

  static func compatibility(_ report: CompatibilityReport) -> Self {
    let contract = report.reference
    if report.installed.bundleIdentifier != contract.bundleIdentifier {
      return Self(
        title: "Unsupported ChatGPT App",
        message: "Install the official ChatGPT app at /Applications/ChatGPT.app.",
        recovery: .installation
      )
    }
    if !report.canLaunch {
      return Self(
        title: "Reinstall ChatGPT",
        message:
          report.launchIssues.joined(separator: "\n"),
        recovery: .installation
      )
    }
    let explanation =
      report.matchesReference
      ? "Your ChatGPT version matches the reference for this Turnrail release."
      : "Your ChatGPT version differs from the reference for this Turnrail release. "
        + "You can still use Turnrail, but some features may behave differently."
    return Self(
      title: "ChatGPT Version",
      message: "Installed: \(report.installed.appVersion) (\(report.installed.appBuild))\n"
        + "Engine: \(report.installed.cliVersion)\n\n"
        + "Release reference: \(contract.appVersion) (\(contract.appBuild))\n"
        + "Engine: \(contract.cliVersion)\n\n"
        + explanation,
      recovery: .releases
    )
  }

  static func compatibilityError(_ error: Error) -> Self {
    if let error = error as? CompatibilityProbeError {
      switch error {
      case .appBundleMissing:
        return Self(
          title: "ChatGPT Not Found",
          message: "Install the official ChatGPT app at /Applications/ChatGPT.app.",
          recovery: .installation
        )
      case .infoPlistMissing, .invalidInfoPlist, .bundledCLIUnavailable, .engineUnavailable:
        return Self(
          title: "Reinstall ChatGPT",
          message: "Reinstall the official ChatGPT app.\n\n" + error.localizedDescription,
          recovery: .installation
        )
      case .commandFailed:
        break
      }
    }
    if let error = error as? RouterPathResolverError {
      switch error {
      case .packagedResourcesUnavailable, .routerIsNotExecutable:
        return Self(
          title: "Reinstall Turnrail",
          message: "Reinstall Codex Turnrail from its release archive.\n\n"
            + error.localizedDescription,
          recovery: .releases
        )
      case .developmentPathMissing, .pathIsNotAbsolute:
        break
      }
    }
    return Self(
      title: "Compatibility Check Failed",
      message: error.localizedDescription,
      recovery: nil
    )
  }
}
