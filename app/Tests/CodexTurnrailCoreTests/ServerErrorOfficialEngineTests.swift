import Foundation
import Testing

@testable import CodexTurnrailCore

extension RouterOfficialEngineTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(3)))
  func serverErrorsRecoverOnTheBoundAccountWithoutRepeatingToolsOrExtendingRetries() throws {
    let installed = try OfficialEngineInstallation.verify(
      app: URL(
        filePath: #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"]))
    )
    let router = URL(
      filePath: try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_ROUTER"]))
    for webSocket in [true, false] {
      let root = try RouterTestDirectory()
      let provider = try FixtureAccounts(root: root.url)
      let backend = FixtureModel()
      let runtime = try RouterRuntime(
        root: root.url, accounts: provider,
        connect: { account, _ in
          FixtureUpstream(account: account.account.id, backend: backend)
        },
        connectHTTP: { account, _ in
          FixtureUpstream(account: account.account.id, backend: backend, transport: "http")
        })
      runtime.start()
      defer { runtime.stop() }
      let home = root.url.appending(path: "home")
      try RouterJSON.privateDirectory(home)
      let authFile = home.appending(path: "auth.json")
      let auth = try RouterJSON.data(["OPENAI_API_KEY": "SYNTHETIC_SERVER_ERROR_RECOVERY"])
      try RouterJSON.writePrivate(auth, to: authFile)
      let endpoint = "http://127.0.0.1:\(runtime.listener.port)/\(runtime.secret)/v1"
      let supportsWebSockets = webSocket ? "true" : "false"
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
          // Exercise both transports and a finite test budget without changing product policy.
          "model_provider=\"server_error_fixture\"",
          "model_providers.server_error_fixture={name=\"OpenAI\",base_url="
            + RouterJSON.quote(endpoint)
            + ",wire_api=\"responses\",requires_openai_auth=true,supports_websockets="
            + supportsWebSockets + ",stream_max_retries=1}",
        ]
      let rpc = try OfficialEngineRPC(
        engine: installed.paths.launcher, home: home, overrides: overrides, timeoutSeconds: 60)
      defer { rpc.close() }
      let marker = root.url.appending(path: "server-error-tool.txt")
      let command: [String: Any] = [
        "cmd": "printf 'executed\\n' >> " + RouterJSON.shellQuote(marker.path)
          + "; printf SERVER_ERROR_TOOL_RESULT",
        "login": false, "yield_time_ms": 10000,
      ]
      backend.setTool("text(await tools.exec_command(" + (try RouterJSON.string(command)) + "));")
      let serverError: [String: Any] = [
        "type": "error", "status": 500,
        "error": [
          "type": "server_error", "code": "server_error", "message": "PRIVATE_SERVER_TEXT",
          "authorization": "PRIVATE_TOKEN", "account_id": "PRIVATE_ACCOUNT",
        ],
      ]
      var executions = 0
      for event in [
        serverError,
        [
          "type": "response.failed",
          "response": ["error": ["code": "server_error", "message": "PRIVATE_SERVER_TEXT"]],
        ],
      ] {
        provider.choose(provider.first.account.id)
        // Reject the inference after a completed command; priority changes must not rebind it.
        backend.reject(event, after: 1, count: 1, at: .created) {
          provider.choose(provider.second.account.id)
        }
        let done = try runServerErrorTurn(rpc, root: root.url)
        try #require(done["status"] as? String == "completed", "\(done)")
        let calls = backend.requests(for: try RouterJSON.text(done, "id"))
        try #require(calls.count == 3)
        #expect(calls.allSatisfy { $0.account == provider.first.account.id })
        #expect(calls.allSatisfy { $0.transport == (webSocket ? "websocket" : "http") })
        let restored = try RouterJSON.array(#require(calls.last).body.value, "input")
        #expect(try RouterJSON.string(restored).contains("SERVER_ERROR_TOOL_RESULT"))
        executions += 1
        #expect(
          try String(contentsOf: marker, encoding: .utf8)
            == String(repeating: "executed\n", count: executions))
        #expect(try !RouterJSON.string(done).contains("PRIVATE_"))
      }

      // A policy refusal must remain terminal even when accompanied by HTTP 500.
      provider.choose(provider.first.account.id)
      backend.rejectNext([
        "type": "error", "status": 500,
        "error": [
          "type": "server_error", "code": "misalignment_policy_violation",
          "message": "PRIVATE_SERVER_TEXT",
        ],
      ])
      let refused = try runServerErrorTurn(rpc, root: root.url)
      #expect(refused["status"] as? String == "failed")
      #expect(
        try RouterJSON.map(refused, "error")["codexErrorInfo"] as? String
          == "misalignmentPolicyViolation")
      #expect(backend.requests(for: try RouterJSON.text(refused, "id")).count == 1)
      #expect(try !RouterJSON.string(refused).contains("PRIVATE_"))

      if !webSocket {
        // With one Engine retry, a persistent server error ends after two HTTP attempts.
        provider.choose(provider.first.account.id)
        backend.reject(serverError, after: 0, count: 20, at: .created) {
          provider.choose(provider.second.account.id)
        }
        let exhausted = try runServerErrorTurn(rpc, root: root.url)
        #expect(exhausted["status"] as? String == "failed")
        #expect(try RouterJSON.string(exhausted).contains("server_error"))
        #expect(try !RouterJSON.string(exhausted).contains("PRIVATE_"))
        let calls = backend.requests(for: try RouterJSON.text(exhausted, "id"))
        #expect(calls.count == 2)
        #expect(
          calls.allSatisfy { $0.account == provider.first.account.id && $0.transport == "http" })
      }
      #expect(
        try String(contentsOf: marker, encoding: .utf8)
          == String(repeating: "executed\n", count: executions))
      #expect(try Data(contentsOf: authFile) == auth)
    }
  }
}

private func runServerErrorTurn(_ rpc: OfficialEngineRPC, root: URL) throws -> [String: Any] {
  let thread = try RouterJSON.text(
    RouterJSON.map(
      rpc.request(
        "thread/start",
        [
          "cwd": root.path, "ephemeral": true, "approvalPolicy": "never",
          "sandbox": "workspace-write",
        ]), "thread"), "id")
  _ = try rpc.request(
    "turn/start",
    [
      "threadId": thread,
      "input": [["type": "text", "text": "Run the marker once and finish.", "text_elements": []]],
    ])
  return try RouterJSON.map(rpc.notification("turn/completed"), "turn")
}
