import Foundation

/// Known layouts inside an independently verified official ChatGPT installation.
public struct OfficialRuntimePaths: Equatable, Sendable {
  public enum Layout: String, Sendable { case flat, packageV1 }

  public let app: URL
  public let layout: Layout
  public let launcher: URL
  public let executable: URL
  public let host: URL
  public let packageVersion: String?

  public static func resolve(app: URL) throws -> Self {
    let app = app.resolvingSymlinksInPath().standardizedFileURL
    let resources = app.appending(path: "Contents/Resources")
    let package = resources.appending(path: "codex-cli")
    let flatEngine = resources.appending(path: "codex")
    let flatHost = resources.appending(path: "codex-code-mode-host")
    let hasPackage = try present(package)
    let hasFlat = try present(flatEngine) || present(flatHost)
    guard hasPackage != hasFlat else {
      throw RouterFailure("ChatGPT has an unknown or ambiguous official Engine layout.")
    }
    if !hasPackage {
      let engine = try checked(flatEngine, inside: app, directory: false, executable: true)
      return Self(
        app: app, layout: .flat, launcher: engine, executable: engine,
        host: try checked(flatHost, inside: app, directory: false, executable: true),
        packageVersion: nil)
    }
    _ = try checked(package, inside: app, directory: true)
    let manifestURL = try checked(
      package.appending(path: "codex-package.json"), inside: app, directory: false)
    let size = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
    guard let size, size <= 1024 * 1024 else {
      throw RouterFailure("The official Engine package manifest exceeds the supported size.")
    }
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    guard manifest.layoutVersion == 1, manifest.target == "aarch64-apple-darwin",
      manifest.variant == "codex", manifest.entrypoint == "bin/codex",
      manifest.resourcesDir == "codex-resources", manifest.pathDir == "codex-path",
      manifest.hasValidVersion
    else { throw RouterFailure("The official Engine package manifest is not supported.") }
    for directory in [manifest.resourcesDir, manifest.pathDir, "CodexCLI.app"] {
      _ = try checked(package.appending(path: directory), inside: app, directory: true)
    }
    return Self(
      app: app, layout: .packageV1,
      launcher: try checked(
        package.appending(path: manifest.entrypoint), inside: app, directory: false,
        executable: true),
      executable: try checked(
        package.appending(path: "CodexCLI.app/Contents/MacOS/codex"), inside: app,
        directory: false, executable: true),
      host: try checked(
        package.appending(path: "bin/codex-code-mode-host"), inside: app,
        directory: false, executable: true),
      packageVersion: manifest.version)
  }

  private struct Manifest: Decodable {
    let layoutVersion: Int
    let version: String
    let target: String
    let variant: String
    let entrypoint: String
    let resourcesDir: String
    let pathDir: String

    var hasValidVersion: Bool {
      let number = "(?:0|[1-9][0-9]*)"
      let identifier = "(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
      let pattern = "^\(number)\\.\(number)\\.\(number)(?:-\(identifier)(?:\\.\(identifier))*)?$"
      return version.range(of: pattern, options: .regularExpression) != nil
        && version.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    }
  }

  private static func present(_ url: URL) throws -> Bool {
    do {
      _ = try FileManager.default.attributesOfItem(atPath: url.path)
      return true
    } catch CocoaError.fileReadNoSuchFile { return false }
  }

  private static func checked(
    _ url: URL, inside app: URL, directory: Bool, executable: Bool = false
  ) throws -> URL {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    guard resolved.path.hasPrefix(app.path + "/") else {
      throw RouterFailure("The official Engine package contains a path outside ChatGPT.")
    }
    let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
    guard directory ? values.isDirectory == true : values.isRegularFile == true,
      !executable || FileManager.default.isExecutableFile(atPath: resolved.path)
    else { throw RouterFailure("A required official Engine component is unavailable: \(url.path)") }
    return resolved
  }
}

public struct OfficialEngineInstallation: Sendable {
  public let paths: OfficialRuntimePaths
  public let identity: CodexInstallation

  @discardableResult
  public static func verify(app: URL, commandExecutor: CommandExecutor = .live) throws -> Self {
    let app = app.resolvingSymlinksInPath().standardizedFileURL
    func verifySignature(_ target: URL, identifier: String?) throws {
      var requirement = "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\""
      if let identifier { requirement += " and identifier \"\(identifier)\"" }
      let result = try commandExecutor.execute(
        URL(filePath: "/usr/bin/codesign"),
        arguments: ["--verify", "--deep", "--strict", "-R=" + requirement, target.path],
        environment: ProcessInfo.processInfo.environment)
      guard result.exitCode == 0 else {
        throw RouterFailure("ChatGPT and its Engine must have valid OpenAI signatures.")
      }
    }
    // The enclosing resource seal authenticates the package manifest and launcher script.
    try verifySignature(app, identifier: "com.openai.codex")
    let paths = try OfficialRuntimePaths.resolve(app: app)
    if paths.layout == .packageV1 {
      let bundle = app.appending(path: "Contents/Resources/codex-cli/CodexCLI.app")
      try verifySignature(bundle, identifier: "codex")
    }
    try verifySignature(
      paths.executable, identifier: paths.layout == .packageV1 ? "codex" : nil)
    try verifySignature(paths.host, identifier: nil)
    let report = try CompatibilityProbe(commandExecutor: commandExecutor).probe(
      appURL: app, engineURL: paths.launcher)
    guard report.canLaunch else {
      throw RouterFailure(report.launchIssues.joined(separator: "\n"))
    }
    return Self(paths: paths, identity: report.installed)
  }
}
