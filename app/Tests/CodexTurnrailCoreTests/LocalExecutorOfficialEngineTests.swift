import Foundation
import Testing

@testable import CodexTurnrailCore

extension RouterOfficialEngineTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(1)))
  func desktopLocalExecutorReachesItsRegistryWithoutAccountRouting() throws {
    let app = URL(
      filePath: try #require(
        ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"]))
    let router = URL(
      filePath: try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_ROUTER"]))
    let engine = try OfficialEngineInstallation.verify(app: app).paths.launcher
    let root = try RouterTestDirectory()
    let registry = root.url.appending(path: "unavailable-registry")
    let authFile = root.url.appending(path: "auth.json")
    let auth = try RouterJSON.data(["OPENAI_API_KEY": "SYNTHETIC_DOT_EXECUTOR"])
    try RouterJSON.writePrivate(auth, to: authFile)
    let configFile = root.url.appending(path: "config.toml")
    let config = Data("approval_policy = \"on-request\"\n".utf8)
    try RouterJSON.writePrivate(config, to: configFile)
    let command = LaunchCommandFactory.makeCodexTurnrailLaunch(
      appURL: app, routerURL: router, engineURL: engine, turnrailRootURL: registry)
    var environment = ProcessInfo.processInfo.environment
    for key in ["CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_ACCESS_TOKEN"] {
      environment.removeValue(forKey: key)
    }
    environment["CODEX_HOME"] = root.url.path
    environment["CODEX_API_KEY"] = "SYNTHETIC_DOT_EXECUTOR"
    for index in command.arguments.indices where command.arguments[index] == "--env" {
      let entry = command.arguments[index + 1].split(separator: "=", maxSplits: 1)
      try #require(entry.count == 2)
      environment[String(entry[0])] = String(entry[1])
    }
    #expect(environment["CODEX_CLI_PATH"] == router.path)
    let executable = URL(
      filePath: try #require(environment["CODEX_TPP_LOCAL_EXECUTOR_CLI_PATH"]))
    #expect(executable == engine)
    let backend = try LocalExecutorRegistryFixture()
    defer { backend.stop() }
    let errors = Pipe()
    let process = try RouterEngineProcess(
      executable: executable,
      arguments: [
        "exec-server", "--remote", backend.url, "--environment-id", "fixture-dot",
        "-c", "cli_auth_credentials_store=\"file\"", "-c", "analytics.enabled=false",
        "-c", "features.remote_models=false",
      ], environment: environment, error: errors.fileHandleForWriting)
    try errors.fileHandleForWriting.close()
    let deadline = DispatchWorkItem { process.forceTerminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
    defer {
      deadline.cancel()
      try? process.input.close()
      try? process.output.close()
      process.stop()
      try? errors.fileHandleForReading.close()
    }
    // The synthetic registry's explicit denial must remain an official Engine error.
    #expect(process.wait() == 1)
    let error = String(
      decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(error.contains("SYNTHETIC_REGISTRY_DENIED"))
    #expect(backend.registrations == 1)
    #expect(!FileManager.default.fileExists(atPath: registry.path))
    #expect(try Data(contentsOf: authFile) == auth)
    #expect(try Data(contentsOf: configFile) == config)
  }
}

private final class LocalExecutorRegistryFixture: @unchecked Sendable {
  private let listener: RouterListener
  private let lock = NSLock()
  private var requests = 0
  var registrations: Int { lock.withLock { requests } }
  var url: String { "http://127.0.0.1:\(listener.port)" }

  init() throws {
    listener = try RouterListener()
    listener.start { [weak self] socket in
      do {
        let request = try socket.request()
        #expect(request.method == "POST")
        #expect(request.path == "/cloud/environment/fixture-dot/register")
        #expect(request.headers["authorization"] == "Bearer SYNTHETIC_DOT_EXECUTOR")
        let size = try #require(request.headers["content-length"].flatMap(Int.init))
        try #require((1...16_384).contains(size))
        let body = try RouterJSON.object(socket.read(size))
        #expect(body["executor_public_key"] != nil)
        #expect(body["security_profile"] as? String == "noise_hybrid_ik_v1")
        self?.lock.withLock { self?.requests += 1 }
        try socket.reply(
          status: 403,
          body: [
            "code": "synthetic_registration_denied", "message": "SYNTHETIC_REGISTRY_DENIED",
          ])
      } catch { Issue.record(error) }
    }
  }

  func stop() { listener.stop() }
}
