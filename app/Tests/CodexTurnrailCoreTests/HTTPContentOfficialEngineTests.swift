import Foundation
import Testing

@testable import CodexTurnrailCore

enum HTTPModelMediaType: CaseIterable, Sendable {
  case eventStream, plainText, json, missing

  var header: String {
    switch self {
    case .eventStream: "Content-Type: text/event-stream\r\n"
    case .plainText: "Content-Type: text/plain\r\n"
    case .json: "Content-Type: application/json\r\n"
    case .missing: ""
    }
  }
}

extension RouterOfficialEngineTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(3)), arguments: HTTPModelMediaType.allCases)
  func httpSSEContentMatchesTheOfficialEngineRegardlessOfMediaType(type: HTTPModelMediaType) throws
  {
    let installed = try OfficialEngineInstallation.verify(
      app: URL(
        filePath: #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"]))
    )
    let router = URL(
      filePath: try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_ROUTER"]))
    // The direct official Engine is the control for the routed HTTP response.
    for routed in [false, true] {
      let root = try RouterTestDirectory()
      let provider = try FixtureAccounts(root: root.url)
      let backend = FixtureModel()
      let model = try HTTPContentModel(backend: backend, type: type)
      defer { model.stop() }
      let runtime = try RouterRuntime(
        root: root.url, accounts: provider,
        connect: { account, _ in FixtureUpstream(account: account.account.id, backend: backend) },
        connectHTTP: { account, _ in model.connect(account: account.account.id) })
      runtime.start()
      defer { runtime.stop() }
      let home = root.url.appending(path: "home")
      try RouterJSON.privateDirectory(home)
      let authFile = home.appending(path: "auth.json")
      let auth = try RouterJSON.data(["OPENAI_API_KEY": "SYNTHETIC_HTTP_CONTENT"])
      try RouterJSON.writePrivate(auth, to: authFile)
      let endpoint =
        routed
        ? "http://127.0.0.1:\(runtime.listener.port)/\(runtime.secret)/v1"
        : model.endpoint
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
          "model_provider=\"http_content_fixture\"",
          "model_providers.http_content_fixture={name=\"OpenAI\",base_url="
            + RouterJSON.quote(endpoint)
            + ",wire_api=\"responses\",requires_openai_auth=true,supports_websockets=false,stream_max_retries=1,http_headers={\"x-fixture-account\"="
            + RouterJSON.quote(provider.first.account.id.uuidString) + "}}",
        ]
      let rpc = try OfficialEngineRPC(
        engine: installed.paths.launcher, home: home, overrides: overrides, timeoutSeconds: 60)
      defer { rpc.close() }
      let marker = root.url.appending(path: "http-content-tool.txt")
      let command: [String: Any] = [
        "cmd": "printf 'executed\\n' >> " + RouterJSON.shellQuote(marker.path)
          + "; printf HTTP_CONTENT_TOOL_RESULT",
        "login": false, "yield_time_ms": 10000,
      ]
      backend.setTool("text(await tools.exec_command(" + (try RouterJSON.string(command)) + "));")
      let thread = try RouterJSON.text(
        RouterJSON.map(
          rpc.request(
            "thread/start",
            [
              "cwd": root.url.path, "ephemeral": true, "approvalPolicy": "never",
              "sandbox": "workspace-write",
            ]), "thread"), "id")
      _ = try rpc.request(
        "turn/start",
        [
          "threadId": thread,
          "input": [
            ["type": "text", "text": "Run the marker once and finish.", "text_elements": []]
          ],
        ])
      let done = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
      try #require(done["status"] as? String == "completed", "routed=\(routed): \(done)")
      let turn = try RouterJSON.text(done, "id")
      let calls = backend.requests(for: turn)
      try #require(calls.count == 2)
      #expect(
        calls.allSatisfy { $0.transport == "http" && $0.account == provider.first.account.id })
      #expect(try String(contentsOf: marker, encoding: .utf8) == "executed\n")
      let restored = try RouterJSON.array(#require(calls.last).body.value, "input")
      #expect(try RouterJSON.string(restored).contains("HTTP_CONTENT_TOOL_RESULT"))
      #expect(try runtime.ledger.bound(thread + "/" + turn) == provider.first.account.id)
      #expect(try Data(contentsOf: authFile) == auth)
    }
  }
}

/// A real HTTP upstream whose SSE body stays identical across media-type declarations.
private final class HTTPContentModel: @unchecked Sendable {
  private let listener: RouterListener
  var endpoint: String { "http://127.0.0.1:\(listener.port)/v1" }

  init(backend: FixtureModel, type: HTTPModelMediaType) throws {
    listener = try RouterListener()
    listener.start { socket in
      do {
        let request = try socket.request()
        #expect(request.method == "POST")
        let lengthText = try #require(request.headers["content-length"])
        let length = try #require(Int(lengthText))
        let accountText = try #require(request.headers["x-fixture-account"])
        let account = try #require(UUID(uuidString: accountText))
        var body = try RouterJSON.object(socket.read(length))
        #expect(body["type"] == nil)
        #expect(body["stream"] as? Bool == true)
        body["type"] = "response.create"
        let events = try backend.response(
          RouterJSON.data(body), account: account, transport: "http")
        try socket.write(
          Data(("HTTP/1.1 200 OK\r\n" + type.header + "Connection: close\r\n\r\n").utf8))
        for event in events {
          try socket.write(Data("data: ".utf8) + event + Data("\n\n".utf8))
        }
      } catch { Issue.record(error) }
    }
  }

  func connect(account: UUID) -> RouterEventStream {
    var request = URLRequest(url: URL(string: endpoint + "/responses")!)
    request.httpMethod = "POST"
    request.setValue(account.uuidString, forHTTPHeaderField: "x-fixture-account")
    return RouterEventStream(accountID: account, request: request)
  }

  func stop() { listener.stop() }
}
