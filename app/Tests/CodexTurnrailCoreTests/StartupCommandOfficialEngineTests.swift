import Darwin
import Foundation
import Testing

@testable import CodexTurnrailCore

extension RouterOfficialEngineTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(1)))
  func desktopStartupCommandPreservesOfficialJSONErrorsAndExplicitSignOut() throws {
    try OfficialEngineStartupCommandFixture.verify(
      app: URL(
        filePath: #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"])),
      router: URL(
        filePath: #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_ROUTER"])))
  }
}

/// Run the desktop's one-shot command with closed stdin, isolated auth, and no router registry.
enum OfficialEngineStartupCommandFixture {
  static func verify(app: URL, router: URL) throws {
    let installed = try OfficialEngineInstallation.verify(app: app)
    let root = try RouterTestDirectory()
    let home = root.url.appending(path: "home")
    try RouterJSON.privateDirectory(home)
    let registry = root.url.appending(path: "unavailable-registry")
    let auth = home.appending(path: "auth.json")
    let originalAuth = try RouterJSON.data(["OPENAI_API_KEY": "SYNTHETIC_STARTUP_COMMAND"])
    let config = home.appending(path: "config.toml")
    let originalConfig = Data(
      "approval_policy = \"on-request\"\nmodel_provider = \"openai\"\n".utf8)
    try RouterJSON.writePrivate(originalConfig, to: config)
    var environment = RouterHelperProcess.environment(
      ProcessInfo.processInfo.environment, engine: installed.paths.launcher)
    environment["CODEX_HOME"] = home.path
    environment["CODEX_TURNRAIL_APP"] = app.path
    environment["CODEX_TURNRAIL_ROOT"] = registry.path
    let args = [
      "app-server", "--analytics-default-enabled", "--print-startup-config",
      "--startup-client-info",
      try RouterJSON.string([
        "name": "codex_desktop", "title": "Codex Desktop", "version": installed.identity.appVersion,
      ]),
      "-c", "cli_auth_credentials_store=\"file\"", "-c", "analytics.enabled=false",
      "-c", "features.remote_models=false",
    ]
    let engine = installed.paths.launcher
    var officialStartup: CommandResult?
    for executable in [engine, router] {
      try RouterJSON.writePrivate(originalAuth, to: auth)
      let result = try run(executable, args: args, environment: environment, root: root.url)
      try #require(result.exitCode == 0)
      let startup = try RouterJSON.object(Data(result.standardOutput.utf8))
      #expect(
        "codex-cli " + (try RouterJSON.text(startup, "appServerVersion"))
          == installed.identity.cliVersion)
      let requirements = try RouterJSON.map(startup, "configRequirements")
      #expect(requirements.keys.contains("requirements"))
      if executable == engine {
        officialStartup = result
      } else {
        #expect(result == officialStartup)
      }
      #expect(try Data(contentsOf: auth) == originalAuth)
      #expect(try Data(contentsOf: config) == originalConfig)
      #expect(!FileManager.default.fileExists(atPath: registry.path))
    }
    // An invalid configuration must keep the official structured failure and exit status.
    try RouterJSON.writePrivate(Data("approval_policy = [\n".utf8), to: config)
    let direct = try run(engine, args: args, environment: environment, root: root.url)
    let routed = try run(router, args: args, environment: environment, root: root.url)
    try #require(direct.exitCode != 0)
    #expect(routed.exitCode == direct.exitCode)
    #expect(routed.standardOutput == direct.standardOutput)
    #expect(routed.standardError == direct.standardError)
    #expect(try RouterJSON.object(Data(routed.standardOutput.utf8))["error"] != nil)
    #expect(try Data(contentsOf: auth) == originalAuth)
    // Restore valid config before testing sign-out; only synthetic file credentials are touched.
    try RouterJSON.writePrivate(originalConfig, to: config)
    for executable in [engine, router] {
      try RouterJSON.writePrivate(originalAuth, to: auth)
      let result = try run(
        executable, args: args + ["--startup-sign-out"], environment: environment, root: root.url)
      #expect(result.exitCode == 0)
      #expect(try RouterJSON.object(Data(result.standardOutput.utf8))["configRequirements"] != nil)
      #expect(!FileManager.default.fileExists(atPath: auth.path))
      #expect(try Data(contentsOf: config) == originalConfig)
      #expect(!FileManager.default.fileExists(atPath: registry.path))
    }
    // Malformed arguments must fail rather than silently succeeding with empty stdout.
    let invalidArgs = args + ["--startup-client-info", "not-json"]
    let directInvalid = try run(engine, args: invalidArgs, environment: environment, root: root.url)
    let routedInvalid = try run(router, args: invalidArgs, environment: environment, root: root.url)
    #expect(directInvalid.exitCode != 0)
    #expect(routedInvalid.exitCode == directInvalid.exitCode)
    #expect(routedInvalid.standardOutput == directInvalid.standardOutput)
    #expect(routedInvalid.standardError == directInvalid.standardError)
    #expect(!FileManager.default.fileExists(atPath: registry.path))
  }

  private static func run(
    _ executable: URL, args: [String], environment: [String: String], root: URL
  ) throws -> CommandResult {
    let errorFile = root.appending(path: "stderr-\(UUID().uuidString)")
    try RouterJSON.writePrivate(Data(), to: errorFile)
    let error = try FileHandle(forWritingTo: errorFile)
    defer { try? error.close() }
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = args
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = error
    try process.run()
    let deadline = DispatchWorkItem {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: deadline)
    defer {
      deadline.cancel()
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationReason == .exit)
    return CommandResult(
      exitCode: process.terminationStatus, standardOutput: String(decoding: data, as: UTF8.self),
      standardError: String(decoding: try Data(contentsOf: errorFile), as: UTF8.self))
  }
}
