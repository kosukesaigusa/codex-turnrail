import Darwin
import Foundation
import Testing

@testable import CodexTurnrailCore

extension RouterOfficialEngineTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(2)))
  func officialEngineCompletesARoutedTurnThroughTheBridge() throws {
    let app = try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"])
    let router = try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_ROUTER"])
    let installed = try OfficialEngineInstallation.verify(app: URL(filePath: app))
    let root = try RouterTestDirectory()
    let home = root.url.appending(path: "home")
    try RouterJSON.privateDirectory(home)
    try RouterJSON.writePrivate(
      RouterJSON.data(["OPENAI_API_KEY": "SYNTHETIC_BRIDGE_TEST"]),
      to: home.appending(path: "auth.json"))
    try RouterJSON.writePrivate(
      Data(
        ("[projects." + RouterJSON.quote(root.url.path) + "]\ntrust_level = \"trusted\"\n").utf8),
      to: home.appending(path: "config.toml"))
    let accounts = try FixtureAccounts(root: root.url)
    let backend = FixtureModel()
    let runtime = try RouterRuntime(
      root: root.url, accounts: accounts,
      connect: { account, _ in FixtureUpstream(account: account.account.id, backend: backend) },
      connectHTTP: { account, _ in
        FixtureUpstream(account: account.account.id, backend: backend, transport: "http")
      })
    runtime.start()
    defer { runtime.stop() }
    let engine = installed.paths.launcher
    let overrides =
      try runtime.configuration(
        engine: engine, home: home, executable: URL(filePath: router)) + [
        "cli_auth_credentials_store=\"file\"", "model=\"gpt-5.6-luna\"",
        "model_reasoning_effort=\"low\"", "features.apps=false", "features.plugins=false",
        "features.memories=false", "analytics.enabled=false", "features.code_mode=true",
        "features.code_mode_host=true", "features.code_mode_only=true", "features.shell_tool=true",
        "approval_policy=\"never\"", "sandbox_mode=\"read-only\"", "web_search=\"disabled\"",
      ]
    let desktopInput = Pipe()
    let desktopOutput = Pipe()
    var sockets: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
    let bridge = FileHandle(fileDescriptor: sockets[0], closeOnDealloc: true)
    let engineSocket = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)
    let process = Process()
    process.executableURL = engine
    process.arguments = ["app-server", "--listen", "stdio://"] + overrides.flatMap { ["-c", $0] }
    process.environment = [
      "PATH": "/usr/bin:/bin", "HOME": home.path, "CODEX_HOME": home.path,
      "CODEX_CLI_PATH": engine.path,
    ]
    process.standardInput = engineSocket
    process.standardOutput = engineSocket
    process.standardError = FileHandle.nullDevice
    try process.run()
    try engineSocket.close()
    let deadline = DispatchWorkItem {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: deadline)
    defer {
      _ = shutdown(bridge.fileDescriptor, SHUT_RDWR)
      try? desktopInput.fileHandleForWriting.close()
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      deadline.cancel()
      try? desktopInput.fileHandleForReading.close()
      try? desktopOutput.fileHandleForReading.close()
      try? desktopOutput.fileHandleForWriting.close()
      try? bridge.close()
    }
    let client = BridgeOfficialClient(
      input: desktopInput.fileHandleForWriting, output: desktopOutput.fileHandleForReading)
    try client.send([
      "id": "initialize", "method": "initialize",
      "params": [
        "clientInfo": ["name": "turnrail-bridge-fixture", "version": "1"],
        "capabilities": ["experimentalApi": true],
      ],
    ])
    let input = try RouterEngineInput(desktopInput.fileHandleForReading)
    let finished = DispatchSemaphore(value: 0)
    let result = BridgeOfficialResult()
    let rootURL = root.url
    DispatchQueue.global().async {
      defer {
        try? desktopOutput.fileHandleForWriting.close()
        finished.signal()
      }
      do {
        let status = try OfficialEngineRouter.relay(
          input: input, engineInput: bridge, engineOutput: bridge,
          desktopOutput: desktopOutput.fileHandleForWriting, home: home,
          executable: URL(filePath: router), engine: engine,
          appVersion: installed.identity.appVersion, runtime: runtime)
        result.complete(status: status, error: nil)
      } catch { result.complete(status: nil, error: error.localizedDescription) }
    }
    #expect(try client.reply("initialize")["error"] == nil)
    try client.send(["method": "initialized"])
    let created = try client.request(
      "thread", "thread/start",
      [
        "cwd": rootURL.path, "ephemeral": true,
        "baseInstructions": "Use only Code Mode to calculate 6 * 7.",
      ])
    let thread = try RouterJSON.text(RouterJSON.map(created, "thread"), "id")
    _ = try client.request(
      "turn", "turn/start",
      [
        "threadId": thread,
        "input": [["type": "text", "text": "Use Code Mode for 6 * 7.", "text_elements": []]],
      ])
    let completed = try RouterJSON.map(client.notification("turn/completed"), "turn")
    try #require(completed["status"] as? String == "completed")
    let turn = try RouterJSON.text(completed, "id")
    let requests = backend.requests(for: turn)
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.account == accounts.first.account.id })
    #expect(try requests.contains { try RouterJSON.string($0.body.value).contains("42") })
    try desktopInput.fileHandleForWriting.close()
    try #require(finished.wait(timeout: .now() + 15) == .success)
    #expect(result.status == 0)
    #expect(result.error == nil)
  }
}

private final class BridgeOfficialClient {
  private let input: FileHandle
  private let reader: EngineLineReader
  private var pending: [[String: Any]] = []

  init(input: FileHandle, output: FileHandle) {
    self.input = input
    reader = EngineLineReader(output)
  }

  func send(_ message: [String: Any]) throws {
    try input.write(contentsOf: RouterJSON.data(message) + Data([10]))
  }

  func request(_ id: String, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
    try send(["id": id, "method": method, "params": params])
    return try RouterJSON.map(reply(id), "result")
  }

  func reply(_ id: String) throws -> [String: Any] {
    try next { $0["method"] == nil && $0["id"] as? String == id }
  }

  func notification(_ method: String) throws -> [String: Any] {
    try RouterJSON.map(next { $0["method"] as? String == method }, "params")
  }

  private func next(_ matches: ([String: Any]) -> Bool) throws -> [String: Any] {
    if let index = pending.firstIndex(where: matches) { return pending.remove(at: index) }
    for _ in 0..<10000 {
      let raw = try reader.next()
      let message = try RouterJSON.object(#require(raw))
      if matches(message) { return message }
      pending.append(message)
    }
    throw RouterFailure("The bridge fixture received too many unmatched messages.")
  }
}

private final class BridgeOfficialResult: @unchecked Sendable {
  private let lock = NSLock()
  private var value: (Int32?, String?) = (nil, nil)
  var status: Int32? { lock.withLock { value.0 } }
  var error: String? { lock.withLock { value.1 } }
  func complete(status: Int32?, error: String?) { lock.withLock { value = (status, error) } }
}
