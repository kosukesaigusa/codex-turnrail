import Foundation
import Testing

@testable import CodexTurnrailCore

extension RouterOfficialEngineTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(1)))
  func desktopStartupReadsOfficialPolicyWithoutRoutingAndPreservesErrors() throws {
    let app = try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"])
    let router = try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_ROUTER"])
    let engine = try OfficialEngineInstallation.verify(app: URL(filePath: app)).paths.launcher
    var officialRequirements: Data?
    var officialError: Data?
    for executable in [engine, URL(filePath: router)] {
      let root = try RouterTestDirectory()
      let registry = root.url.appending(path: "unavailable-registry")
      let auth = root.url.appending(path: "auth.json")
      try RouterJSON.writePrivate(
        RouterJSON.data(["OPENAI_API_KEY": "SYNTHETIC_STARTUP_POLICY"]), to: auth)
      var environment = RouterHelperProcess.environment(
        ProcessInfo.processInfo.environment, engine: engine)
      environment["CODEX_HOME"] = root.url.path
      environment["CODEX_TURNRAIL_APP"] = app
      environment["CODEX_TURNRAIL_ROOT"] = registry.path
      let client = try StartupPolicyClient(executable: executable, environment: environment)
      defer { client.close() }
      let initialized = try client.request(startupInitialization())
      #expect(initialized["error"] == nil)
      try client.send(["method": "initialized"])
      let requirements = try client.request([
        "id": "network-requirements", "method": "configRequirements/read", "params": [:],
      ])
      let data = try RouterJSON.data(RouterJSON.map(requirements, "result"))
      if executable == engine {
        officialRequirements = data
      } else {
        #expect(data == officialRequirements)
        let blocked = try client.request([
          "id": "blocked-inference", "method": "turn/start", "params": [:],
        ])
        #expect(try RouterJSON.map(blocked, "error")["code"] as? Int == -32602)
        #expect(
          try RouterJSON.map(blocked, "error")["message"] as? String
            == "The desktop startup connection only supports organization policy checks.")
      }
      let invalid = try client.request([
        "id": "invalid-policy", "method": "configRequirements/read", "params": "invalid",
      ])
      let error = try RouterJSON.data(RouterJSON.map(invalid, "error"))
      if executable == engine {
        officialError = error
      } else {
        #expect(error == officialError)
      }
      let logout = try client.request([
        "id": "network-logout", "method": "account/logout", "params": [:],
      ])
      #expect(logout["error"] == nil)
      #expect(!FileManager.default.fileExists(atPath: auth.path))
      let afterLogout = try client.request([
        "id": "after-logout", "method": "configRequirements/read", "params": [:],
      ])
      #expect(afterLogout["error"] == nil)
      #expect(!FileManager.default.fileExists(atPath: registry.path))
    }
  }
}

private final class StartupPolicyClient {
  private let process: RouterEngineProcess
  private let reader: EngineLineReader
  private let deadline: DispatchWorkItem

  init(executable: URL, environment: [String: String]) throws {
    process = try RouterEngineProcess(
      executable: executable,
      arguments: [
        "app-server", "--listen", "stdio://", "-c", "cli_auth_credentials_store=\"file\"",
        "-c", "analytics.enabled=false", "-c", "features.remote_models=false",
      ], environment: environment, error: FileHandle.nullDevice)
    reader = EngineLineReader(process.output)
    let process = process
    deadline = DispatchWorkItem { process.forceTerminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
  }

  func send(_ message: [String: Any]) throws {
    try process.input.write(contentsOf: RouterJSON.data(message) + Data([10]))
  }

  func request(_ message: [String: Any]) throws -> [String: Any] {
    let id = try RouterJSON.text(message, "id")
    try send(message)
    for _ in 0..<100 {
      guard let raw = try reader.next() else { throw RouterFailure("The startup fixture exited.") }
      let response = try RouterJSON.object(raw)
      if response["id"] as? String == id, response["method"] == nil { return response }
    }
    throw RouterFailure("The startup fixture produced too many unmatched messages.")
  }

  func close() {
    deadline.cancel()
    try? process.input.close()
    process.stop()
  }
}
