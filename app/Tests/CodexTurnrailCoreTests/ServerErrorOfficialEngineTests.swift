import Foundation
import Testing

@testable import CodexTurnrailCore

extension RouterOfficialEngineTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(3)), arguments: [500, 502, 503, 504])
  func serverErrorsRecoverOnTheBoundAccountWithoutRepeatingToolsOrExtendingRetries(status: Int)
    throws
  {
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
      let httpModel = try ServerErrorHTTPModel(backend: backend)
      defer { httpModel.stop() }
      let runtime = try RouterRuntime(
        root: root.url, accounts: provider,
        connect: { account, _ in
          FixtureUpstream(account: account.account.id, backend: backend)
        },
        connectHTTP: { account, _ in
          httpModel.connect(account: account.account.id)
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
        "type": "error", "status": status,
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
        ["type": "error", "status": status, "error": [:]],
        ["type": "error", "code": "server_error", "message": "PRIVATE_SERVER_TEXT"],
        [
          "type": "error",
          "error": ["type": "service_unavailable_error", "code": "server_is_overloaded"],
          "headers": NSNull(),
        ],
        ["type": "error", "code": "server_is_overloaded", "message": "PRIVATE_SERVER_TEXT"],
        [
          "type": "error", "status": status,
          "error": ["type": "service_unavailable_error", "code": "server_is_overloaded"],
          "headers": ["Retry-After": "1", "authorization": "PRIVATE_TOKEN"],
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
        if event["headers"] is [String: Any] {
          #expect(calls[2].time.timeIntervalSince(calls[1].time) >= 1)
        }
        let diagnostics = try Data(
          contentsOf: root.url.appending(path: "router/service-diagnostics.json"))
        let entry = try #require(RouterJSON.array(RouterJSON.object(diagnostics), "entries").last)
        #expect(entry["permitsEngineRecovery"] as? Bool == true)
        #expect(entry["transport"] as? String == (webSocket ? "websocket" : "http"))
        let responseStarted = webSocket || event["status"] == nil
        #expect(try RouterJSON.map(entry, "request")["responseStarted"] as? Bool == responseStarted)
        #expect(!String(decoding: diagnostics, as: UTF8.self).contains("PRIVATE_"))
        executions += 1
        #expect(
          try String(contentsOf: marker, encoding: .utf8)
            == String(repeating: "executed\n", count: executions))
        #expect(try !RouterJSON.string(done).contains("PRIVATE_"))
      }

      // A policy refusal must remain terminal even when accompanied by a recoverable status.
      provider.choose(provider.first.account.id)
      backend.rejectNext([
        "type": "error", "status": status,
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

      // An unclassified error has no evidence authorizing replay. Keep a useful private record.
      backend.rejectNext([
        "type": "error", "error": ["code": "PRIVATE_UNKNOWN_CODE", "message": "PRIVATE_TEXT"],
      ])
      let unclassified = try runServerErrorTurn(rpc, root: root.url)
      #expect(unclassified["status"] as? String == "failed")
      #expect(backend.requests(for: try RouterJSON.text(unclassified, "id")).count == 1)
      #expect(try RouterJSON.string(unclassified).contains("reason unavailable or unrecognized"))
      #expect(try RouterJSON.string(unclassified).contains("ref:"))
      #expect(try !RouterJSON.string(unclassified).contains("PRIVATE_"))
      let diagnosticData = try Data(
        contentsOf: root.url.appending(path: "router/service-diagnostics.json"))
      let last = try #require(RouterJSON.array(RouterJSON.object(diagnosticData), "entries").last)
      #expect(try RouterJSON.map(last, "code")["state"] as? String == "unrecognized")
      #expect(last["permitsEngineRecovery"] as? Bool == false)

      // Diagnostics are observational: a storage error must not block valid Engine recovery.
      let diagnosticFile = root.url.appending(path: "router/service-diagnostics.json")
      try Data("INVALID_ARCHIVE".utf8).write(to: diagnosticFile)
      backend.rejectNext(serverError)
      let recoveredWithoutArchive = try runServerErrorTurn(rpc, root: root.url)
      #expect(recoveredWithoutArchive["status"] as? String == "completed")
      executions += 1
      #expect(try String(contentsOf: diagnosticFile, encoding: .utf8) == "INVALID_ARCHIVE")
      try FileManager.default.removeItem(at: diagnosticFile)

      // Remote compaction has its own Engine retry loop and must retain the same binding.
      provider.choose(provider.first.account.id)
      let compactThread = try startServerErrorThread(rpc, root: root.url)
      _ = try rpc.request(
        "turn/start",
        [
          "threadId": compactThread,
          "input": [["type": "text", "text": "Run the marker once.", "text_elements": []]],
        ])
      let beforeCompact = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
      try #require(beforeCompact["status"] as? String == "completed")
      executions += 1
      provider.choose(provider.second.account.id)
      backend.rejectNext([
        "type": "error", "status": 503,
        "error": ["type": "service_unavailable_error", "code": "server_is_overloaded"],
      ])
      _ = try rpc.request("thread/compact/start", ["threadId": compactThread])
      let compact = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
      #expect(compact["status"] as? String == "completed")
      let compactCalls = backend.requests(for: try RouterJSON.text(compact, "id"))
      #expect(compactCalls.count == 2)
      #expect(compactCalls.allSatisfy { $0.account == provider.first.account.id })
      let compactLog = try RouterJSON.object(Data(contentsOf: diagnosticFile))
      let compactEntry = try #require(RouterJSON.array(compactLog, "entries").last)
      #expect(try RouterJSON.map(compactEntry, "request")["kind"] as? String == "compaction")

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
        #expect(httpModel.httpStatuses.contains(status))
      }
      #expect(
        try String(contentsOf: marker, encoding: .utf8)
          == String(repeating: "executed\n", count: executions))
      #expect(try Data(contentsOf: authFile) == auth)
    }
  }
}

/// Emits real HTTP error statuses before starting SSE, using only synthetic account data.
private final class ServerErrorHTTPModel: @unchecked Sendable {
  private let listener: RouterListener
  private let lock = NSLock()
  private var statuses: [Int] = []
  var httpStatuses: [Int] { lock.withLock { statuses } }

  init(backend: FixtureModel) throws {
    listener = try RouterListener()
    listener.start { [weak self] socket in
      guard let self else { return }
      do {
        let request = try socket.request()
        let length = try #require(Int(RouterJSON.text(request.headers, "content-length")))
        let account = try #require(
          UUID(uuidString: RouterJSON.text(request.headers, "x-fixture-account")))
        var body = try RouterJSON.object(socket.read(length))
        #expect(request.method == "POST")
        #expect(body["type"] == nil)
        body["type"] = "response.create"
        let events = try backend.response(
          RouterJSON.data(body), account: account, transport: "http")
        for event in events {
          let value = try RouterJSON.object(event)
          if value["type"] as? String == "error", let status = value["status"] as? Int {
            lock.withLock { statuses.append(status) }
            let data = try RouterJSON.data(["error": RouterJSON.map(value, "error")])
            let retryHeader: String
            if let headers = value["headers"] as? [String: Any] {
              retryHeader = "Retry-After: \(try RouterJSON.text(headers, "Retry-After"))\r\n"
            } else {
              retryHeader = ""
            }
            try socket.write(
              Data(
                ("HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\n"
                  + retryHeader + "Content-Length: \(data.count)\r\nConnection: close\r\n\r\n").utf8
              )
                + data)
            return
          }
        }
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

private func startServerErrorThread(_ rpc: OfficialEngineRPC, root: URL) throws -> String {
  try RouterJSON.text(
    RouterJSON.map(
      rpc.request(
        "thread/start",
        [
          "cwd": root.path, "ephemeral": true, "approvalPolicy": "never",
          "sandbox": "workspace-write",
        ]), "thread"), "id")
}

private func runServerErrorTurn(_ rpc: OfficialEngineRPC, root: URL) throws -> [String: Any] {
  let thread = try startServerErrorThread(rpc, root: root)
  _ = try rpc.request(
    "turn/start",
    [
      "threadId": thread,
      "input": [["type": "text", "text": "Run the marker once and finish.", "text_elements": []]],
    ])
  return try RouterJSON.map(rpc.notification("turn/completed"), "turn")
}
