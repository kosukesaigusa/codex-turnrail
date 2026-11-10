import Darwin
import Foundation
import Security
import Testing

@testable import CodexTurnrailCore

extension RouterOfficialEngineTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(1)))
  func engineUnblocksInheritedTerminationSignal() throws {
    let app = try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"])
    let router = try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_ROUTER"])
    let root = try RouterTestDirectory()
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = root.url.path
    environment["CODEX_TURNRAIL_APP"] = app
    environment["CODEX_TURNRAIL_ROOT"] = root.url.appending(path: "registry").path
    let process = try RouterEngineProcess(
      executable: URL(filePath: "/usr/bin/env"),
      arguments: [
        "python3", "-c",
        "import os,signal,sys;signal.pthread_sigmask(signal.SIG_BLOCK,{signal.SIGTERM});"
          + "os.execv(sys.argv[1],sys.argv[1:])", router,
        "app-server", "--listen", "stdio://", "-c", "features.remote_models=false",
      ], environment: environment, error: .nullDevice)
    let deadline = DispatchWorkItem { process.forceTerminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: deadline)
    defer {
      deadline.cancel()
      process.stop()
    }
    try process.input.write(contentsOf: RouterJSON.data(startupInitialization()) + Data([10]))
    let raw = try EngineLineReader(process.output).next()
    #expect(try RouterJSON.object(#require(raw))["id"] as? String == "network-initialize")
    try #require(kill(process.pid, SIGTERM) == 0)
    var information = siginfo_t()
    for _ in 0..<500 {
      try #require(waitid(P_PID, id_t(process.pid), &information, WEXITED | WNOHANG | WNOWAIT) == 0)
      if information.si_pid == process.pid { break }
      Thread.sleep(forTimeInterval: 0.02)
    }
    try #require(information.si_pid == process.pid)
    _ = process.wait()
  }

  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(1)))
  func routerStartsWithARestrictedDescriptorLimit() throws {
    let app = try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"])
    let router = try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_ROUTER"])
    let root = try RouterTestDirectory()
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = root.url.path
    environment["CODEX_TURNRAIL_APP"] = app
    environment["CODEX_TURNRAIL_ROOT"] = root.url.appending(path: "registry").path
    let process = try RouterEngineProcess(
      executable: URL(filePath: "/bin/sh"),
      arguments: [
        "-c", "ulimit -n 128; exec \"$@\"", "turnrail-test", router,
        "app-server", "--listen", "stdio://", "-c", "features.remote_models=false",
      ], environment: environment, error: .nullDevice)
    let deadline = DispatchWorkItem { process.forceTerminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
    defer {
      deadline.cancel()
      process.stop()
    }
    try process.input.write(contentsOf: RouterJSON.data(startupInitialization()) + Data([10]))
    let raw = try EngineLineReader(process.output).next()
    let reply = try RouterJSON.object(#require(raw))
    #expect(reply["id"] as? String == "network-initialize")
    #expect(reply["error"] == nil)
  }

  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(1)), arguments: [false, true])
  func bridgeStopsWhenItsEngineExits(initialized: Bool) throws {
    let app = try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"])
    let router = try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_ROUTER"])
    let root = try RouterTestDirectory()
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = root.url.path
    environment["CODEX_TURNRAIL_APP"] = app
    environment["CODEX_TURNRAIL_ROOT"] = root.url.appending(path: "registry").path
    let process = try RouterEngineProcess(
      executable: URL(filePath: router), arguments: ["app-server", "--listen", "stdio://"],
      environment: environment, error: .nullDevice)
    let deadline = DispatchWorkItem { process.forceTerminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 50, execute: deadline)
    defer {
      deadline.cancel()
      process.stop()
    }
    if initialized {
      try process.input.write(contentsOf: RouterJSON.data(startupInitialization()) + Data([10]))
      let raw = try EngineLineReader(process.output).next()
      #expect(try RouterJSON.object(#require(raw))["id"] as? String == "network-initialize")
    }
    var bridge: pid_t?
    for _ in 0..<300 {
      let search = try CommandExecutor.live.execute(
        URL(filePath: "/usr/bin/pgrep"),
        arguments: ["-P", "\(process.pid)", "-f", "router-bridge"], environment: [:])
      if let pid = pid_t(search.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)) {
        bridge = pid
        break
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    let bridgePID = try #require(bridge)
    try #require(kill(process.pid, SIGKILL) == 0)
    for _ in 0..<500 where kill(bridgePID, 0) == 0 { Thread.sleep(forTimeInterval: 0.02) }
    #expect(kill(bridgePID, 0) == -1 && errno == ESRCH)
    #expect(process.wait() == 1)
  }

  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(1)))
  func routerReportsStartupFailureAndRemovesItsRuntimeSession() throws {
    let app = try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"])
    let router = try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_ROUTER"])
    let root = try RouterTestDirectory()
    let registry = root.url.appending(path: "registry")
    let errors = Pipe()
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = root.url.path
    environment["CODEX_TURNRAIL_APP"] = app
    environment["CODEX_TURNRAIL_ROOT"] = registry.path
    let process = try RouterEngineProcess(
      executable: URL(filePath: router), arguments: ["app-server", "--listen", "stdio://"],
      environment: environment, error: errors.fileHandleForWriting)
    let deadline = DispatchWorkItem { process.forceTerminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
    defer {
      deadline.cancel()
      process.stop()
      try? errors.fileHandleForReading.close()
      try? errors.fileHandleForWriting.close()
    }
    try errors.fileHandleForWriting.close()
    try process.input.write(
      contentsOf: RouterJSON.data([
        "id": "normal-initialize", "method": "initialize", "params": [:],
      ]) + Data([10]))
    #expect(process.wait() == 1)
    let error = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(error.contains("The Turnrail account registry is missing."))
    let sessions = registry.appending(path: "router/sessions")
    let remaining = try FileManager.default.contentsOfDirectory(atPath: sessions.path)
    #expect(remaining.isEmpty)
  }

  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(1)))
  func desktopStartupReadsPolicyAndConfigurationWithoutRoutingAndPreservesErrors() throws {
    let app = try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"])
    let router = try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_ROUTER"])
    let engine = try OfficialEngineInstallation.verify(app: URL(filePath: app)).paths.launcher
    var officialRequirements: Data?
    var officialError: Data?
    var officialConfigError: Data?
    for executable in [engine, URL(filePath: router)] {
      let root = try RouterTestDirectory()
      let registry = root.url.appending(path: "unavailable-registry")
      let auth = root.url.appending(path: "auth.json")
      let originalAuth = try RouterJSON.data(["OPENAI_API_KEY": "SYNTHETIC_STARTUP_POLICY"])
      try RouterJSON.writePrivate(originalAuth, to: auth)
      let configFile = root.url.appending(path: "config.toml")
      let originalConfig = Data(
        "approval_policy = \"on-request\"\nmodel_provider = \"openai\"\n".utf8)
      try RouterJSON.writePrivate(originalConfig, to: configFile)
      var environment = RouterHelperProcess.environment(
        ProcessInfo.processInfo.environment, engine: engine)
      environment["CODEX_HOME"] = root.url.path
      environment["CODEX_TURNRAIL_APP"] = app
      environment["CODEX_TURNRAIL_ROOT"] = registry.path
      let client = try StartupPolicyClient(executable: executable, environment: environment)
      defer { client.close() }
      let initialized = try client.request(startupInitialization())
      #expect(initialized["error"] == nil)
      // The desktop's native browser authorizer checks the Engine's signing identity
      // in the original child PID, not merely the identity of a descendant process.
      try client.expectOfficialEngineInOriginalProcess()
      try client.send(["method": "initialized"])
      let requirements = try client.request([
        "id": "network-requirements", "method": "configRequirements/read", "params": [:],
      ])
      let data = try RouterJSON.data(RouterJSON.map(requirements, "result"))
      if executable == engine {
        officialRequirements = data
      } else {
        #expect(data == officialRequirements)
      }
      let configuration = try client.request([
        "id": "network-config", "method": "config/read", "params": ["includeLayers": false],
      ])
      let config = try RouterJSON.map(RouterJSON.map(configuration, "result"), "config")
      #expect(try RouterJSON.text(config, "approval_policy") == "on-request")
      #expect(try RouterJSON.text(config, "model_provider") == "openai")
      if executable != engine {
        for method in ["turn/start", "thread/start", "command/exec", "config/value/write"] {
          let blocked = try client.request([
            "id": "blocked-\(method)", "method": method, "params": [:],
          ])
          #expect(try RouterJSON.map(blocked, "error")["code"] as? Int == -32602)
          #expect(
            try RouterJSON.map(blocked, "error")["message"] as? String
              == "The desktop startup connection only supports organization policy checks.")
        }
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
      let invalidConfig = try client.request([
        "id": "invalid-config", "method": "config/read", "params": "invalid",
      ])
      let configError = try RouterJSON.data(RouterJSON.map(invalidConfig, "error"))
      if executable == engine {
        officialConfigError = configError
      } else {
        #expect(configError == officialConfigError)
      }
      #expect(try Data(contentsOf: auth) == originalAuth)
      #expect(try Data(contentsOf: configFile) == originalConfig)
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
      #expect(try Data(contentsOf: configFile) == originalConfig)
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

  func expectOfficialEngineInOriginalProcess() throws {
    var code: SecCode?
    try #require(
      SecCodeCopyGuestWithAttributes(
        nil, [kSecGuestAttributePid: process.pid] as CFDictionary, SecCSFlags(), &code)
        == errSecSuccess)
    var requirement: SecRequirement?
    let expression =
      "anchor apple generic and identifier \"codex\""
      + " and certificate leaf[subject.OU] = \"2DC432GLL2\""
    try #require(
      SecRequirementCreateWithString(expression as CFString, SecCSFlags(), &requirement)
        == errSecSuccess)
    let verifiedCode = try #require(code)
    let verifiedRequirement = try #require(requirement)
    #expect(SecCodeCheckValidity(verifiedCode, SecCSFlags(), verifiedRequirement) == errSecSuccess)
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
