import CodexTurnrailCore
import Foundation

struct StatusNotice: Equatable, Identifiable {
  enum Recovery: Equatable {
    case releases
    case installation

    var title: String {
      switch self {
      case .releases: "View Releases"
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
    if report.isCompatible {
      return Self(
        title: "Compatible",
        message: "This version of the ChatGPT app is supported.",
        recovery: nil
      )
    }
    let contract = CodexCompatibilityContract.supported
    if report.engineVersion != contract.cliVersion {
      return Self(
        title: "Reinstall Turnrail",
        message: "Reinstall Codex Turnrail from its release archive.\n\n"
          + report.mismatches.joined(separator: "\n"),
        recovery: .releases
      )
    }
    if report.installed.bundleIdentifier != contract.bundleIdentifier {
      return Self(
        title: "Unsupported ChatGPT App",
        message: "Install the supported ChatGPT app at /Applications/ChatGPT.app.",
        recovery: .installation
      )
    }
    if report.installed.appVersion == contract.appVersion,
      report.installed.appBuild == contract.appBuild,
      report.installed.cliVersion != contract.cliVersion
    {
      return Self(
        title: "Reinstall ChatGPT",
        message:
          "The ChatGPT app contains an unsupported Codex CLI. Reinstall the supported ChatGPT app.",
        recovery: .installation
      )
    }
    return Self(
      title: "Unsupported ChatGPT Version",
      message: "Installed: \(report.installed.appVersion) (\(report.installed.appBuild))\n"
        + "Supported: \(contract.appVersion) (\(contract.appBuild))\n\n"
        + "Check the Turnrail releases for support for your ChatGPT app version.",
      recovery: .releases
    )
  }

  static func compatibilityError(_ error: Error) -> Self {
    if let error = error as? CompatibilityProbeError {
      switch error {
      case .appBundleMissing:
        return Self(
          title: "ChatGPT Not Found",
          message: "Install the supported ChatGPT app at /Applications/ChatGPT.app.",
          recovery: .installation
        )
      case .infoPlistMissing, .invalidInfoPlist, .bundledCLIUnavailable:
        return Self(
          title: "Reinstall ChatGPT",
          message: "Reinstall the supported ChatGPT app.\n\n" + error.localizedDescription,
          recovery: .installation
        )
      case .engineUnavailable:
        return Self(
          title: "Reinstall Turnrail",
          message: "Reinstall Codex Turnrail from its release archive.\n\n"
            + error.localizedDescription,
          recovery: .releases
        )
      case .commandFailed:
        break
      }
    }
    if let error = error as? EnginePathResolverError {
      switch error {
      case .packagedResourcesUnavailable, .engineIsNotExecutable:
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
