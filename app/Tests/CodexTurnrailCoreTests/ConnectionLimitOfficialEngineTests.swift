import Foundation
import Testing

@testable import CodexTurnrailCore

enum ConnectionExpiryStage: String, CaseIterable, Sendable {
  case created, text, tool, completedTool
}

extension RouterOfficialEngineTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(2)), arguments: ConnectionExpiryStage.allCases)
  func expiredResponsesReconnectOnTheBoundAccountWithoutRepeatingTools(
    stage: ConnectionExpiryStage
  ) throws {
    let installed = try OfficialEngineInstallation.verify(
      app: URL(
        filePath: #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"]))
    )
    let router = URL(
      filePath: try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_ROUTER"]))
    let root = try RouterTestDirectory()
    let provider = try FixtureAccounts(root: root.url)
    let backend = FixtureModel()
    let runtime = try RouterRuntime(
      root: root.url, accounts: provider,
      connect: { account, _ in
        FixtureUpstream(account: account.account.id, backend: backend)
      })
    runtime.start()
    defer { runtime.stop() }
    let home = root.url.appending(path: "home")
    try RouterJSON.privateDirectory(home)
    let authFile = home.appending(path: "auth.json")
    let auth = try RouterJSON.data(["OPENAI_API_KEY": "SYNTHETIC_CONNECTION_EXPIRY"])
    try RouterJSON.writePrivate(auth, to: authFile)
    let endpoint = "http://127.0.0.1:\(runtime.listener.port)/\(runtime.secret)/v1"
    let overrides =
      try runtime.configuration(engine: installed.paths.launcher, home: home, executable: router)
      + [
        "cli_auth_credentials_store=\"file\"", "model=\"gpt-5.6-luna\"",
        "model_reasoning_effort=\"low\"",
        "features.apps=false", "features.plugins=false", "features.memories=false",
        "analytics.enabled=false", "web_search=\"disabled\"",
        "features.code_mode=true", "features.code_mode_host=true", "features.code_mode_only=true",
        "features.shell_tool=true", "approval_policy=\"never\"",
        "sandbox_mode=\"workspace-write\"", "features.unbounded_connection_retries=false",
        "model_provider=\"connection_limit_fixture\"",
        "model_providers.connection_limit_fixture={name=\"OpenAI\",base_url="
          + RouterJSON.quote(endpoint)
          + ",wire_api=\"responses\",requires_openai_auth=true,supports_websockets=true,stream_max_retries=1}",
      ]
    let rpc = try OfficialEngineRPC(
      engine: installed.paths.launcher, home: home, overrides: overrides, timeoutSeconds: 60)
    defer { rpc.close() }
    let marker = root.url.appending(path: "connection-expiry-tool.txt")
    let command: [String: Any] = [
      "cmd": "printf 'executed\\n' >> " + RouterJSON.shellQuote(marker.path)
        + "; printf CONNECTION_EXPIRY_TOOL_RESULT",
      "login": false, "yield_time_ms": 10000,
    ]
    backend.setTool("text(await tools.exec_command(" + (try RouterJSON.string(command)) + "));")
    let event: [String: Any] = [
      "type": "error", "status": 400,
      "error": [
        "type": "invalid_request_error", "code": "websocket_connection_limit_reached",
        "message": "PRIVATE_SERVER_TEXT", "authorization": "PRIVATE_TOKEN",
      ],
    ]
    let point: FixtureModel.ResponsePoint
    switch stage {
    case .created, .completedTool: point = .created
    case .text: point = .text
    case .tool: point = .tool
    }
    provider.choose(provider.first.account.id)
    backend.reject(event, after: stage == .completedTool ? 1 : 0, count: 1, at: point) {
      provider.choose(provider.second.account.id)
    }
    let thread = try RouterJSON.text(
      RouterJSON.map(
        rpc.request(
          "thread/start",
          [
            "cwd": root.url.path, "ephemeral": true, "approvalPolicy": "never",
            "sandbox": "workspace-write",
          ]), "thread"), "id")
    let start = try rpc.request(
      "turn/start",
      [
        "threadId": thread,
        "input": [
          ["type": "text", "text": "Run the marker once and finish.", "text_elements": []]
        ],
      ])
    let turn = try RouterJSON.text(RouterJSON.map(start, "turn"), "id")
    let done = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
    try #require(done["status"] as? String == "completed", "\(done)")
    let calls = backend.requests(for: turn)
    try #require(calls.count == (stage == .tool ? 2 : 3))
    #expect(calls.allSatisfy { $0.account == provider.first.account.id })
    #expect(calls.allSatisfy { $0.transport == "websocket" })
    #expect(backend.openedAccounts == [provider.first.account.id, provider.first.account.id])
    let resumed = calls[stage == .completedTool ? 2 : 1].body.value
    #expect(resumed["previous_response_id"] == nil)
    if stage == .text {
      #expect(try RouterJSON.string(resumed).contains("PARTIAL_ASSISTANT_NOTE"))
    }
    let restored = try RouterJSON.array(#require(calls.last).body.value, "input")
    let outputs = restored.filter { $0["type"] as? String == "custom_tool_call_output" }
    #expect(outputs.count == 1)
    #expect(try RouterJSON.string(outputs).contains("CONNECTION_EXPIRY_TOOL_RESULT"))
    #expect(try String(contentsOf: marker, encoding: .utf8) == "executed\n")
    #expect(try runtime.ledger.bound(thread + "/" + turn) == provider.first.account.id)
    #expect(try Data(contentsOf: authFile) == auth)
    #expect(try !RouterJSON.string(done).contains("PRIVATE_"))
  }
}
