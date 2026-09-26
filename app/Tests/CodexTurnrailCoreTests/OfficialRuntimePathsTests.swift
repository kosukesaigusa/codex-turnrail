import Foundation
import Testing

@testable import CodexTurnrailCore

struct OfficialRuntimePathsTests {
  @Test(arguments: [false, true])
  func resolvesTheLauncherAndActualExecutables(packaged: Bool) throws {
    let root = try RouterTestDirectory()
    let app = try fixture(root.url, packaged: packaged)
    let paths = try OfficialRuntimePaths.resolve(app: app)
    #expect(paths.layout == (packaged ? .packageV1 : .flat))
    #expect(paths.launcher == app.appending(path: packaged ? package + "/bin/codex" : flat))
    #expect(paths.executable == app.appending(path: packaged ? binary : flat))
    #expect(
      paths.host == app.appending(path: packaged ? host : "Contents/Resources/codex-code-mode-host")
    )
    #expect((paths.packageVersion != nil) == packaged)
  }

  @Test(arguments: ["missing", "ambiguous", "brokenPackage", "missingHost", "notExecutable"])
  func rejectsIncompleteOrAmbiguousLayouts(problem: String) throws {
    let root = try RouterTestDirectory()
    let app = try fixture(root.url, packaged: problem != "brokenPackage")
    let files = FileManager.default
    switch problem {
    case "missing": try files.removeItem(at: app.appending(path: package))
    case "ambiguous": try write(app.appending(path: flat), "fixture")
    case "brokenPackage":
      try files.createSymbolicLink(
        atPath: app.appending(path: package).path, withDestinationPath: "missing")
    case "missingHost": try files.removeItem(at: app.appending(path: host))
    case "notExecutable":
      try files.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: app.appending(path: binary).path)
    default: Issue.record("Unknown fixture")
    }
    #expect(throws: (any Error).self) { try OfficialRuntimePaths.resolve(app: app) }
  }

  @Test(arguments: [
    "layoutVersion", "target", "variant", "entrypoint", "resourcesDir", "pathDir", "version",
    "missing",
  ])
  func rejectsUnsupportedPackageMetadata(field: String) throws {
    let root = try RouterTestDirectory()
    let app = try fixture(root.url, packaged: true)
    let url = app.appending(path: package + "/codex-package.json")
    var manifest = try RouterJSON.object(Data(contentsOf: url))
    if field == "missing" {
      manifest.removeValue(forKey: "entrypoint")
    } else {
      manifest[field] = field == "layoutVersion" ? 2 : "../unknown"
    }
    try RouterJSON.data(manifest).write(to: url)
    #expect(throws: (any Error).self) { try OfficialRuntimePaths.resolve(app: app) }
  }

  @Test(arguments: [
    "Contents/Resources/codex-cli/bin/codex",
    "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
    "Contents/Resources/codex-cli/bin/codex-code-mode-host",
    "Contents/Resources/codex-cli/codex-package.json", "Contents/Resources/codex",
  ])
  func rejectsLinksOutsideTheOfficialApp(path: String) throws {
    let root = try RouterTestDirectory()
    let app = try fixture(root.url, packaged: path != flat)
    let target = app.appending(path: path)
    let outside = root.url.appending(path: "outside")
    try FileManager.default.moveItem(at: target, to: outside)
    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
    #expect(throws: (any Error).self) { try OfficialRuntimePaths.resolve(app: app) }
  }

  @Test(arguments: [0, 1, 2, 3])
  func noLauncherRunsWhenAnyRequiredSignatureFails(index: Int) throws {
    let root = try RouterTestDirectory()
    let app = try fixture(root.url, packaged: true)
    let trace = Trace(failingSignature: index)
    #expect(throws: (any Error).self) {
      try OfficialEngineInstallation.verify(app: app, commandExecutor: trace.executor)
    }
    #expect(trace.versionExecutions == 0)
    #expect(trace.signatures.count == index + 1)
  }

  @Test(arguments: [false, true])
  func signatureChecksPrecedeTheSingleLauncherExecution(packaged: Bool) throws {
    let root = try RouterTestDirectory()
    let app = try fixture(root.url, packaged: packaged)
    let trace = Trace(failingSignature: nil)
    let installed = try OfficialEngineInstallation.verify(app: app, commandExecutor: trace.executor)
    #expect(installed.identity.cliVersion == "codex-cli 0.158.0-alpha.2")
    #expect(
      trace.signatures
        == (packaged
          ? [
            app.path, app.appending(path: package + "/CodexCLI.app").path,
            app.appending(path: binary).path, app.appending(path: host).path,
          ]
          : [
            app.path, app.appending(path: flat).path,
            app.appending(path: "Contents/Resources/codex-code-mode-host").path,
          ]))
    #expect(trace.executedLauncher == installed.paths.launcher)
    #expect(trace.versionExecutions == 1)
    #expect(trace.requirements[0].hasSuffix(" and identifier \"com.openai.codex\""))
    if packaged {
      #expect(trace.requirements[1].hasSuffix(" and identifier \"codex\""))
      #expect(trace.requirements[2].hasSuffix(" and identifier \"codex\""))
    }
  }

  @Test
  func anExternalLauncherIsRejectedEvenIfItWouldReportTheSameVersion() throws {
    let root = try RouterTestDirectory()
    let app = try fixture(root.url, packaged: true)
    let trace = Trace(failingSignature: nil)
    #expect(throws: (any Error).self) {
      try CompatibilityProbe(commandExecutor: trace.executor).probe(
        appURL: app, engineURL: root.url.appending(path: "other-codex"))
    }
    #expect(trace.versionExecutions == 0)
  }

  @Test
  func theExecutableVersionMustAgreeWithItsManifest() throws {
    let root = try RouterTestDirectory()
    let app = try fixture(root.url, packaged: true)
    let path = app.appending(path: package + "/codex-package.json")
    var manifest = try RouterJSON.object(Data(contentsOf: path))
    manifest["version"] = "0.999.0"
    try RouterJSON.data(manifest).write(to: path)
    #expect(throws: (any Error).self) {
      try OfficialEngineInstallation.verify(
        app: app, commandExecutor: Trace(failingSignature: nil).executor)
    }
  }

  private let package = "Contents/Resources/codex-cli"
  private let flat = "Contents/Resources/codex"
  private let binary = "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
  private let host = "Contents/Resources/codex-cli/bin/codex-code-mode-host"

  private func fixture(_ root: URL, packaged: Bool) throws -> URL {
    let app = root.appending(path: "ChatGPT.app")
    let info: [String: String] = [
      "CFBundleIdentifier": "com.openai.codex", "CFBundleShortVersionString": "26.924.20706",
      "CFBundleVersion": "11431",
    ]
    try write(app.appending(path: "Contents/Info.plist"), "")
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: app.appending(path: "Contents/Info.plist"))
    if packaged {
      for directory in ["codex-path", "codex-resources"] {
        try FileManager.default.createDirectory(
          at: app.appending(path: package + "/" + directory), withIntermediateDirectories: true)
      }
      try write(
        app.appending(path: package + "/codex-package.json"),
        #"{"layoutVersion":1,"version":"0.158.0-alpha.2","target":"aarch64-apple-darwin","variant":"codex","entrypoint":"bin/codex","resourcesDir":"codex-resources","pathDir":"codex-path"}"#
      )
      for path in [package + "/bin/codex", binary, host] {
        try write(app.appending(path: path), "fixture")
      }
    } else {
      for path in [flat, "Contents/Resources/codex-code-mode-host"] {
        try write(app.appending(path: path), "fixture")
      }
    }
    return app
  }

  private func write(_ path: URL, _ text: String) throws {
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
  }

  private final class Trace: @unchecked Sendable {
    let lock = NSLock()
    let failingSignature: Int?
    var signatures: [String] = []
    var requirements: [String] = []
    var versionExecutions = 0
    var executedLauncher: URL?
    init(failingSignature: Int?) { self.failingSignature = failingSignature }
    var executor: CommandExecutor {
      CommandExecutor { url, arguments, _ in
        self.lock.withLock {
          if url.path == "/usr/bin/codesign" {
            let index = self.signatures.count
            self.signatures.append(arguments.last!)
            self.requirements.append(arguments[3])
            return CommandResult(
              exitCode: self.failingSignature == index ? 1 : 0, standardOutput: "",
              standardError: "")
          }
          self.versionExecutions += 1
          self.executedLauncher = url
          return CommandResult(
            exitCode: 0, standardOutput: "codex-cli 0.158.0-alpha.2\n", standardError: "")
        }
      }
    }
  }
}
