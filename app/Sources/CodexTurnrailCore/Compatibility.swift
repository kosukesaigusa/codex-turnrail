import Foundation

public struct CodexCompatibilityContract: Equatable, Sendable {
  public let bundleIdentifier: String
  public let appVersion: String
  public let appBuild: String
  public let cliVersion: String

  public init(
    bundleIdentifier: String,
    appVersion: String,
    appBuild: String,
    cliVersion: String
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.appVersion = appVersion
    self.appBuild = appBuild
    self.cliVersion = cliVersion
  }

}

public struct CodexInstallation: Equatable, Sendable {
  public let bundleIdentifier: String
  public let appVersion: String
  public let appBuild: String
  public let cliVersion: String

  public init(
    bundleIdentifier: String,
    appVersion: String,
    appBuild: String,
    cliVersion: String
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.appVersion = appVersion
    self.appBuild = appBuild
    self.cliVersion = cliVersion
  }
}

public struct CompatibilityReport: Equatable, Sendable {
  public let installed: CodexInstallation
  public let engineVersion: String
  public let mismatches: [String]

  public var isCompatible: Bool {
    mismatches.isEmpty
  }

  public init(
    installed: CodexInstallation,
    engineVersion: String,
    mismatches: [String]
  ) {
    self.installed = installed
    self.engineVersion = engineVersion
    self.mismatches = mismatches
  }
}

public enum CompatibilityProbeError: LocalizedError, Equatable {
  case appBundleMissing(String)
  case infoPlistMissing(String)
  case invalidInfoPlist(String)
  case bundledCLIUnavailable(String)
  case engineUnavailable(String)
  case commandFailed(executable: String, exitCode: Int32, message: String)

  public var errorDescription: String? {
    switch self {
    case .appBundleMissing(let path):
      "ChatGPT app was not found at \(path)."
    case .infoPlistMissing(let path):
      "ChatGPT Info.plist was not found at \(path)."
    case .invalidInfoPlist(let key):
      "ChatGPT Info.plist does not contain a valid \(key)."
    case .bundledCLIUnavailable(let path):
      "The bundled Codex CLI is not executable at \(path)."
    case .engineUnavailable(let path):
      "The Turnrail Engine is not executable at \(path)."
    case .commandFailed(let executable, let exitCode, let message):
      "\(executable) exited with code \(exitCode): \(message)"
    }
  }
}

public struct CompatibilityProbe {
  private let contract: CodexCompatibilityContract
  private let commandExecutor: CommandExecutor
  private let fileManager: FileManager

  public init(
    contract: CodexCompatibilityContract = .supported,
    commandExecutor: CommandExecutor = .live,
    fileManager: FileManager = .default
  ) {
    self.contract = contract
    self.commandExecutor = commandExecutor
    self.fileManager = fileManager
  }

  public func probe(appURL: URL, engineURL: URL) throws -> CompatibilityReport {
    let installed = try inspectInstallation(appURL: appURL)
    let engineVersion = try readVersion(
      executableURL: engineURL,
      unavailableError: .engineUnavailable(engineURL.path)
    )

    return CompatibilityReport(
      installed: installed,
      engineVersion: engineVersion,
      mismatches: CompatibilityEvaluator.evaluate(
        contract: contract,
        installed: installed,
        engineVersion: engineVersion
      )
    )
  }

  private func inspectInstallation(appURL: URL) throws -> CodexInstallation {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: appURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw CompatibilityProbeError.appBundleMissing(appURL.path)
    }

    let infoPlistURL = appURL.appending(path: "Contents/Info.plist")
    guard fileManager.fileExists(atPath: infoPlistURL.path) else {
      throw CompatibilityProbeError.infoPlistMissing(infoPlistURL.path)
    }

    let data = try Data(contentsOf: infoPlistURL)
    guard
      let plist = try PropertyListSerialization.propertyList(
        from: data,
        format: nil
      ) as? [String: Any]
    else {
      throw CompatibilityProbeError.invalidInfoPlist("property list")
    }

    let bundleIdentifier = try requiredString("CFBundleIdentifier", in: plist)
    let appVersion = try requiredString("CFBundleShortVersionString", in: plist)
    let appBuild = try requiredString("CFBundleVersion", in: plist)
    let cliURL = appURL.appending(path: "Contents/Resources/codex")
    let cliVersion = try readVersion(
      executableURL: cliURL,
      unavailableError: .bundledCLIUnavailable(cliURL.path)
    )

    return CodexInstallation(
      bundleIdentifier: bundleIdentifier,
      appVersion: appVersion,
      appBuild: appBuild,
      cliVersion: cliVersion
    )
  }

  private func requiredString(
    _ key: String,
    in propertyList: [String: Any]
  ) throws -> String {
    guard let value = propertyList[key] as? String,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw CompatibilityProbeError.invalidInfoPlist(key)
    }
    return value
  }

  private func readVersion(
    executableURL: URL,
    unavailableError: CompatibilityProbeError
  ) throws -> String {
    guard fileManager.isExecutableFile(atPath: executableURL.path) else {
      throw unavailableError
    }

    let result = try commandExecutor.execute(
      executableURL,
      arguments: ["--version"],
      environment: ProcessInfo.processInfo.environment
    )
    guard result.exitCode == 0 else {
      let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
      throw CompatibilityProbeError.commandFailed(
        executable: executableURL.path,
        exitCode: result.exitCode,
        message: message
      )
    }

    return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public enum CompatibilityEvaluator {
  public static func evaluate(
    contract: CodexCompatibilityContract,
    installed: CodexInstallation,
    engineVersion: String
  ) -> [String] {
    var mismatches: [String] = []

    if installed.bundleIdentifier != contract.bundleIdentifier {
      mismatches.append(
        "Bundle identifier \(installed.bundleIdentifier) is not supported."
      )
    }
    if installed.appVersion != contract.appVersion {
      mismatches.append("App version \(installed.appVersion) is not supported.")
    }
    if installed.appBuild != contract.appBuild {
      mismatches.append("App build \(installed.appBuild) is not supported.")
    }
    if installed.cliVersion != contract.cliVersion {
      mismatches.append(
        "Bundled CLI \(installed.cliVersion) does not match \(contract.cliVersion)."
      )
    }
    if engineVersion != contract.cliVersion {
      mismatches.append(
        "Turnrail Engine \(engineVersion) does not match \(contract.cliVersion)."
      )
    }

    return mismatches
  }
}
