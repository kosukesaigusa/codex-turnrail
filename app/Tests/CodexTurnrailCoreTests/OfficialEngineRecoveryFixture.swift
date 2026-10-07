import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterRecoveryEngineTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(2)))
  func httpModelWaitingHasNoRouterDeadline() throws {
    let app = URL(
      filePath: try #require(
        ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"]))
    _ = try OfficialEngineInstallation.verify(app: app)
    try OfficialEngineWaitingFixture.verifyHTTPWaiting(
      app: app,
      router: URL(
        filePath: #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_ROUTER"])))
  }

  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(2)))
  func officialEngineRecoversInterruptedStreams() throws {
    try OfficialEngineRecoveryFixture.verify(
      app: URL(
        filePath: #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"])),
      router: URL(
        filePath: #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_ROUTER"])))
  }
}

enum OfficialEngineRecoveryFixture {
  static func verify(app: URL, router: URL) throws {
    let installed = try OfficialEngineInstallation.verify(app: app)
    let root = try RouterTestDirectory()
    let provider = try FixtureAccounts(root: root.url)
    let backend = FixtureModel()
    let http = try RecoveryHTTPModel(backend: backend)
    defer { http.stop() }
    let runtime = try RouterRuntime(
      root: root.url, accounts: provider,
      connect: { account, _ in FixtureUpstream(account: account.account.id, backend: backend) },
      connectHTTP: { account, _ in
        http.connect(account: account.account.id)
      })
    runtime.start()
    defer { runtime.stop() }
    let home = root.url.appending(path: "home")
    try RouterJSON.privateDirectory(home)
    try RouterJSON.writePrivate(
      RouterJSON.data(["OPENAI_API_KEY": "SYNTHETIC_LOCAL_RECOVERY_TEST"]),
      to: home.appending(path: "auth.json"))
    let engine = installed.paths.launcher
    let endpoint = "http://127.0.0.1:\(runtime.listener.port)/\(runtime.secret)/v1"
    let overrides =
      try runtime.configuration(engine: engine, home: home, executable: router) + [
        "cli_auth_credentials_store=\"file\"", "model=\"gpt-5.6-luna\"",
        "model_reasoning_effort=\"low\"",
        "features.apps=false", "features.plugins=false", "features.memories=false",
        "analytics.enabled=false",
        "features.code_mode=true", "features.code_mode_host=true", "features.code_mode_only=true",
        "features.shell_tool=true", "approval_policy=\"never\"", "sandbox_mode=\"workspace-write\"",
        "web_search=\"disabled\"", "features.unbounded_connection_retries=false",
        // Exercise the real transport transition without changing the product's retry policy.
        "model_provider=\"recovery_fixture\"",
        "model_providers.recovery_fixture={name=\"OpenAI\",base_url=" + RouterJSON.quote(endpoint)
          + ",wire_api=\"responses\",requires_openai_auth=true,supports_websockets=true,stream_max_retries=1}",
      ]
    let rpc = try OfficialEngineRPC(
      engine: engine, home: home, overrides: overrides, timeoutSeconds: 60)
    defer { rpc.close() }
    let marker = root.url.appending(path: "recovery-tool.txt")
    let command: [String: Any] = [
      "cmd": "printf 'executed\\n' >> " + RouterJSON.shellQuote(marker.path)
        + "; printf RECOVERED_TOOL_RESULT",
      "login": false, "yield_time_ms": 10000,
    ]
    backend.setTool("text(await tools.exec_command(" + (try RouterJSON.string(command)) + "));")
    // Failure before creation, during text, after a completed tool response, and
    // after tool dispatch but before response.completed exercise distinct Engine history paths.
    for (after, at, expected): (Int, FixtureModel.ResponsePoint, Int) in [
      (0, .empty, 3), (0, .text, 3), (1, .created, 3), (0, .tool, 2),
    ] {
      let thread = try startThread(rpc, root: root.url)
      let executionsBefore = try executions(marker)
      provider.choose(provider.first.account.id)
      backend.interrupt(after: after, count: 1, at: at) {
        provider.choose(provider.second.account.id)
      }
      let result = try run(rpc, thread: thread)
      let details = try RouterJSON.string(result)
      try #require(result["status"] as? String == "completed", "\(details)")
      let calls = backend.requests(for: try RouterJSON.text(result, "id"))
      #expect(calls.count == expected)
      #expect(
        calls.allSatisfy { $0.account == provider.first.account.id && $0.transport == "websocket" })
      #expect(try executions(marker) == executionsBefore + 1)
      let restored = try RouterJSON.array(#require(calls.last).body.value, "input")
      #expect(try RouterJSON.string(restored).contains("RECOVERED_TOOL_RESULT"))
      if at == .text {
        #expect(try RouterJSON.string(calls[1].body.value).contains("PARTIAL_ASSISTANT_NOTE"))
      }
    }

    // Two WebSocket attempts exhaust the configured test budget, then HTTP itself
    // loses a stream once. The Engine must recover again and keep using the same account.
    let thread = try startThread(rpc, root: root.url)
    provider.choose(provider.first.account.id)
    backend.interrupt(after: 0, count: 3, at: .created) {
      provider.choose(provider.second.account.id)
    }
    let beforeHTTP = try executions(marker)
    let recovered = try run(rpc, thread: thread)
    let recoveredDetails = try RouterJSON.string(recovered)
    try #require(
      recovered["status"] as? String == "completed", "\(recoveredDetails)")
    let calls = backend.requests(for: try RouterJSON.text(recovered, "id"))
    #expect(calls.map(\.transport) == ["websocket", "websocket", "http", "http", "http"])
    #expect(calls.allSatisfy { $0.account == provider.first.account.id })
    #expect(try executions(marker) == beforeHTTP + 1)

    // HTTP service errors and safety refusals remain terminal, including after output begins.
    for (code, afterCreated) in [
      ("token_revoked", false), ("usage_limit_reached", true),
      ("misalignment_policy_violation", true),
    ] {
      backend.reject(
        [
          "type": "error", "status": 400,
          "error": [
            "type": "invalid_request_error", "code": code, "message": "PRIVATE_SERVER_TEXT",
          ],
        ],
        after: 0, count: 1, at: afterCreated ? .created : .empty, onRejection: {})
      let rejected = try run(rpc, thread: thread)
      #expect(rejected["status"] as? String == "failed")
      #expect(try RouterJSON.string(rejected).contains(code))
      #expect(try !RouterJSON.string(rejected).contains("PRIVATE_SERVER_TEXT"))
      #expect(backend.requests(for: try RouterJSON.text(rejected, "id")).count == 1)
      if code == "misalignment_policy_violation" {
        #expect(
          try RouterJSON.map(rejected, "error")["codexErrorInfo"] as? String
            == "misalignmentPolicyViolation")
      }
    }
    let next = try run(rpc, thread: thread)
    #expect(next["status"] as? String == "completed")
    let nextCalls = backend.requests(for: try RouterJSON.text(next, "id"))
    #expect(nextCalls.count == 2)
    #expect(
      nextCalls.allSatisfy { $0.account == provider.second.account.id && $0.transport == "http" })

    // The router must not extend the Engine's retry budget during a persistent outage.
    backend.interrupt(after: 0, count: 20, at: .created, onInterruption: {})
    let exhausted = try run(rpc, thread: thread)
    #expect(exhausted["status"] as? String == "failed")
    #expect(backend.requests(for: try RouterJSON.text(exhausted, "id")).count == 2)
  }

  private static func startThread(_ rpc: OfficialEngineRPC, root: URL) throws -> String {
    try RouterJSON.text(
      RouterJSON.map(
        rpc.request(
          "thread/start",
          [
            "cwd": root.path, "ephemeral": true, "approvalPolicy": "never",
            "sandbox": "workspace-write",
          ]), "thread"), "id")
  }

  private static func run(_ rpc: OfficialEngineRPC, thread: String) throws -> [String: Any] {
    _ = try rpc.request(
      "turn/start",
      [
        "threadId": thread,
        "input": [
          ["type": "text", "text": "Run the fixture tool once and finish.", "text_elements": []]
        ],
      ])
    return try RouterJSON.map(rpc.notification("turn/completed"), "turn")
  }

  private static func executions(_ marker: URL) throws -> Int {
    if !FileManager.default.fileExists(atPath: marker.path) { return 0 }
    let lines = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n")
    #expect(lines.allSatisfy { $0 == "executed" })
    return lines.count
  }
}

/// Real Foundation HTTP streaming on the router's upstream side, with synthetic model events.
private final class RecoveryHTTPModel: @unchecked Sendable {
  private let listener: RouterListener

  init(backend: FixtureModel) throws {
    listener = try RouterListener()
    listener.start { socket in
      do {
        let request = try socket.request()
        let length = try #require(request.headers["content-length"])
        let accountText = try #require(request.headers["x-fixture-account"])
        let account = try #require(UUID(uuidString: accountText))
        var body = try RouterJSON.object(socket.read(#require(Int(length))))
        #expect(body["type"] == nil)
        body["type"] = "response.create"
        let events = try backend.response(
          RouterJSON.data(body), account: account, transport: "http")
        try socket.write(
          Data(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n".utf8))
        for event in events {
          try socket.write(Data("data: ".utf8) + event + Data("\n\n".utf8))
        }
      } catch { Issue.record(error) }
    }
  }

  func connect(account: UUID) -> RouterEventStream {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(listener.port)/responses")!)
    request.httpMethod = "POST"
    request.setValue(account.uuidString, forHTTPHeaderField: "x-fixture-account")
    return RouterEventStream(accountID: account, request: request)
  }

  func stop() { listener.stop() }
}
