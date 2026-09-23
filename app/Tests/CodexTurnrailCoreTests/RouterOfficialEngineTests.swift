import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterOfficialEngineTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(1)))
  func officialAuthenticationProtocolReadsWithoutRewritingCredentials() throws {
    let app = URL(
      filePath: try #require(
        ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"]))
    try OfficialEngineInstallation.verify(app: app)
    let root = try RouterTestDirectory()
    let authFile = root.url.appending(path: "auth.json")
    let auth = try RouterJSON.data(["OPENAI_API_KEY": "SYNTHETIC_AUTH_PROTOCOL_TEST"])
    try RouterJSON.writePrivate(auth, to: authFile)
    let modified = try authFile.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
    for _ in 0..<3 {
      let rpc = try OfficialEngineRPC(
        engine: app.appending(path: "Contents/Resources/codex"), home: root.url,
        overrides: ["cli_auth_credentials_store=\"file\""])
      defer { rpc.close() }
      let status = try rpc.request(
        "getAuthStatus", ["includeToken": true, "refreshToken": false])
      #expect(status["authMethod"] as? String == "apikey")
      #expect(status["authToken"] as? String == "SYNTHETIC_AUTH_PROTOCOL_TEST")
      #expect(try Data(contentsOf: authFile) == auth)
      #expect(
        try authFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
          == modified)
    }
  }

  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(1)), arguments: ["task", "plugin"])
  func desktopHelperCanReadPolicyWithTheOfficialCLI(source: String) throws {
    let appPath = try #require(
      ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"])
    let routerPath = try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_ROUTER"])
    let app = URL(filePath: appPath)
    let installed = try OfficialEngineInstallation.verify(app: app)
    let engine = app.appending(path: "Contents/Resources/codex")
    let root = try RouterTestDirectory()
    let helper: [String: Any] = ["env": ["CODEX_CLI_PATH": routerPath]]
    let prepared: [String: Any]
    if source == "plugin" {
      let file = root.url.appending(
        path: "plugins/cache/openai-bundled/unified-computer-use/"
          + installed.appVersion + "/.mcp.json")
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try RouterJSON.writePrivate(RouterJSON.data(["mcpServers": ["cua_repl": helper]]), to: file)
      try RouterHelperConfiguration.synchronizePlugin(
        home: root.url, router: URL(filePath: routerPath), engine: engine,
        appVersion: installed.appVersion)
      prepared = try RouterJSON.map(
        RouterJSON.map(RouterJSON.object(Data(contentsOf: file)), "mcpServers"), "cua_repl")
    } else {
      let message = RouterHelperConfiguration.prepare(
        [
          "id": "desktop", "method": "thread/resume",
          "params": ["config": ["mcp_servers.cua_repl": helper]],
        ], router: URL(filePath: routerPath), engine: engine)
      let config = try RouterJSON.map(RouterJSON.map(message, "params"), "config")
      prepared = try RouterJSON.map(config, "mcp_servers.cua_repl")
    }
    let environment = try RouterJSON.map(prepared, "env")
    let executable = URL(filePath: try RouterJSON.text(environment, "CODEX_CLI_PATH"))
    let rpc = try OfficialEngineRPC(
      engine: executable, home: root.url,
      overrides: ["browser_use.default_origin_policy.access=\"deny\""])
    defer { rpc.close() }
    let response = try rpc.request("config/read", ["cwd": root.url.path, "includeLayers": false])
    let browser = try RouterJSON.map(RouterJSON.map(response, "config"), "browser_use")
    let policy = try RouterJSON.map(browser, "default_origin_policy")
    #expect(try RouterJSON.text(policy, "access") == "deny")
    let requirements = try rpc.request("configRequirements/read", [:])
    #expect(requirements.keys.contains("requirements"))
  }

  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(3)))
  func officialEngineExecutesCodeModeAndTitlesThroughTheNativeRouter() throws {
    let appPath = try #require(
      ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"])
    let routerPath = try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_ROUTER"])
    let app = URL(filePath: appPath)
    try OfficialEngineInstallation.verify(app: app)
    let root = try RouterTestDirectory()
    let provider = try FixtureAccounts(root: root.url)
    let backend = FixtureModel()
    let searches = FixtureSearch()
    let failures = FixtureFailures()
    let runtime = try RouterRuntime(
      root: root.url, accounts: provider,
      connect: { account, _ in
        FixtureUpstream(account: account.account.id, backend: backend)
      }, search: { try searches.send($0) }, reportFailure: { failures.append($0) })
    runtime.start()
    defer { runtime.stop() }
    let home = root.url.appending(path: "home")
    try RouterJSON.privateDirectory(home)
    try RouterJSON.writePrivate(
      RouterJSON.data(["OPENAI_API_KEY": "SYNTHETIC_LOCAL_ROUTER_TEST"]),
      to: home.appending(path: "auth.json"))
    let engine = app.appending(path: "Contents/Resources/codex")
    let userHookMarker = root.url.appending(path: "user-hook.txt")
    let userCommand = "printf 'invoked\\n' >> " + RouterJSON.shellQuote(userHookMarker.path)
    let hookFile = home.appending(path: "hooks.json")
    let userHooks = try RouterJSON.data([
      "hooks": ["UserPromptSubmit": [["hooks": [["type": "command", "command": userCommand]]]]]
    ])
    try RouterJSON.writePrivate(userHooks, to: hookFile)
    let inspection = try OfficialEngineRPC(
      engine: engine, home: home, overrides: ["features.hooks=true"])
    let inspected = try RouterJSON.array(
      inspection.request("hooks/list", ["cwds": [root.url.path]]), "data")
    let inspectedHooks = try RouterJSON.array(inspected[0], "hooks")
    let userHook = try #require(inspectedHooks.first)
    inspection.close()
    let userConfig = Data(
      ("[hooks.state]\n"
        + RouterJSON.quote(try RouterJSON.text(userHook, "key"))
        + "={trusted_hash=" + RouterJSON.quote(try RouterJSON.text(userHook, "currentHash"))
        + "}\n\n[projects." + RouterJSON.quote(root.url.path) + "]\ntrust_level = \"trusted\"\n")
        .utf8)
    let configFile = home.appending(path: "config.toml")
    try RouterJSON.writePrivate(userConfig, to: configFile)
    let fixtureOverrides = [
      "cli_auth_credentials_store=\"file\"", "model=\"gpt-5.6-luna\"",
      "model_reasoning_effort=\"low\"",
      "features.apps=false", "features.plugins=false", "features.memories=false",
      "analytics.enabled=false",
      "features.code_mode=true", "features.code_mode_host=true", "features.code_mode_only=true",
      "features.shell_tool=true", "approval_policy=\"never\"", "sandbox_mode=\"read-only\"",
      "web_search=\"disabled\"",
    ]
    let overrides = try runtime.configuration(
      engine: engine, home: home, executable: URL(filePath: routerPath))
    let rpc = try OfficialEngineRPC(
      engine: engine, home: home, overrides: overrides + fixtureOverrides, timeoutSeconds: 120)
    defer { rpc.close() }
    let hookData = try RouterJSON.array(
      rpc.request("hooks/list", ["cwds": [root.url.path]]), "data")
    let hooks = try RouterJSON.array(hookData[0], "hooks")
    #expect(hooks.count == 4)
    #expect(hooks.allSatisfy { $0["trustStatus"] as? String == "trusted" })
    let created = try rpc.request(
      "thread/start",
      [
        "cwd": root.url.path, "ephemeral": true,
        "baseInstructions":
          "Use only Code Mode to calculate 6 * 7. Do not create agents or access files.",
      ])
    let thread = try RouterJSON.text(RouterJSON.map(created, "thread"), "id")
    for account in [provider.first, provider.second] {
      provider.choose(account.account.id)
      _ = try rpc.request(
        "turn/start",
        [
          "threadId": thread,
          "input": [["type": "text", "text": "Use Code Mode for 6 * 7.", "text_elements": []]],
        ])
      let result = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
      try #require(result["status"] as? String == "completed", "\(failures.messages)")
      let turn = try RouterJSON.text(result, "id")
      let calls = backend.requests(for: turn)
      #expect(calls.count == 2)
      #expect(calls.allSatisfy { $0.account == account.account.id })
      let outputs = try calls.flatMap { try RouterJSON.array($0.body.value, "input") }.filter {
        $0["type"] as? String == "custom_tool_call_output"
      }
      #expect(try outputs.contains { try RouterJSON.string($0).contains("42") })
      if account.account.id == provider.second.account.id {
        let switched = try #require(calls.first)
        #expect(switched.body.value["previous_response_id"] == nil)
        let inherited = try RouterJSON.array(switched.body.value, "input")
        #expect(inherited.contains { $0["type"] as? String == "custom_tool_call_output" })
      }
    }
    // An idle connection can expire before the next user turn is submitted.
    // Reconnect before sending, retaining history and the same account.
    backend.expireConnections()
    _ = try rpc.request(
      "turn/start",
      [
        "threadId": thread,
        "input": [["type": "text", "text": "Calculate again after idle.", "text_elements": []]],
      ])
    let afterIdle = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
    try #require(afterIdle["status"] as? String == "completed", "\(failures.messages)")
    let afterIdleCalls = backend.requests(for: try RouterJSON.text(afterIdle, "id"))
    #expect(afterIdleCalls.count == 2)
    #expect(afterIdleCalls.allSatisfy { $0.account == provider.second.account.id })
    let reconnected = try #require(afterIdleCalls.first)
    #expect(reconnected.body.value["previous_response_id"] == nil)
    let restored = try RouterJSON.array(reconnected.body.value, "input")
    #expect(restored.contains { $0["type"] as? String == "custom_tool_call_output" })
    // A manual compaction must retain the completed turn's account even after
    // folder priority changes, without needing another UserPromptSubmit hook.
    provider.choose(provider.first.account.id)
    _ = try rpc.request("thread/compact/start", ["threadId": thread])
    let compactResult = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
    let compactDetails = try RouterJSON.string(compactResult)
    try #require(
      compactResult["status"] as? String == "completed",
      "\(failures.messages), \(compactDetails)")
    let compactCalls = backend.requests(for: try RouterJSON.text(compactResult, "id"))
    #expect(compactCalls.count == 1)
    #expect(compactCalls.allSatisfy { $0.account == provider.second.account.id })
    #expect(
      try compactCalls.allSatisfy {
        try RouterRequest.metadata($0.body.value)["request_kind"] as? String == "compaction"
      })
    provider.choose(provider.second.account.id)
    let observer = RouterEngineObserver()
    try observer.request([
      "id": "title-registration", "method": "thread/start",
      "params": ["threadSource": "thread_title", "config": ["features.hooks": false]],
    ])
    let title = try rpc.request(
      "thread/start",
      [
        "cwd": root.url.path, "ephemeral": true, "threadSource": "thread_title",
        "baseInstructions": "Return a short title. Do not call tools.",
        "config": ["features.hooks": false],
      ])
    let titleThread = try RouterJSON.map(title, "thread")
    try observer.response(
      ["id": "title-registration", "result": title], register: runtime.registerTitle)
    _ = try rpc.request(
      "turn/start",
      [
        "threadId": RouterJSON.text(titleThread, "id"), "turnTrigger": "thread_title",
        "input": [
          ["type": "text", "text": "Title this synthetic routing check.", "text_elements": []]
        ],
      ])
    let titleResult = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
    #expect(titleResult["status"] as? String == "completed")
    #expect(
      backend.requests(for: try RouterJSON.text(titleResult, "id")).allSatisfy {
        $0.account == provider.second.account.id
      })
    #expect(backend.requests(for: try RouterJSON.text(titleResult, "id")).count == 1)
    let completedItems = try rpc.takeNotifications("item/completed")
    let titleID = try RouterJSON.text(titleThread, "id")
    let titleItems = completedItems.filter { $0["threadId"] as? String == titleID }
    #expect(try titleItems.contains { try RouterJSON.string($0).contains("Verify routing") })
    for decision in ["accept", "decline"] {
      let marker = root.url.appending(path: decision + ".txt")
      let command: [String: Any] = [
        "cmd": "printf TURNRAIL_APPROVED > " + RouterJSON.shellQuote(marker.path), "login": false,
        "yield_time_ms": 10000, "sandbox_permissions": "require_escalated",
        "justification": "Verify the isolated Turnrail approval marker.",
      ]
      backend.setTool("text(await tools.exec_command(" + (try RouterJSON.string(command)) + "));")
      let created = try rpc.request(
        "thread/start",
        [
          "cwd": root.url.path, "ephemeral": true, "approvalPolicy": "on-request",
          "approvalsReviewer": "user", "sandbox": "workspace-write",
        ])
      let id = try RouterJSON.text(RouterJSON.map(created, "thread"), "id")
      _ = try rpc.request(
        "turn/start",
        [
          "threadId": id,
          "input": [
            ["type": "text", "text": "Run the isolated marker check.", "text_elements": []]
          ],
        ])
      var approvals = 0
      let done = try rpc.notification("turn/completed") { method, params in
        let details = try RouterJSON.string(params)
        #expect(method == "item/commandExecution/requestApproval")
        #expect(details.contains(marker.path))
        approvals += 1
        return ["decision": decision]
      }
      #expect(try RouterJSON.map(done, "turn")["status"] as? String == "completed")
      #expect(approvals == 1)
      #expect(FileManager.default.fileExists(atPath: marker.path) == (decision == "accept"))
    }
    #expect(try Data(contentsOf: hookFile) == userHooks)
    let remainingConfig = try String(contentsOf: configFile, encoding: .utf8)
    #expect(Data(remainingConfig.utf8) == userConfig, "\(remainingConfig)")
    #expect(
      try String(contentsOf: userHookMarker, encoding: .utf8).components(separatedBy: "invoked")
        .count == 6)
    #expect(failures.messages.count == 1)
    #expect(failures.messages.first?.hasPrefix("Reconnecting before sending [") == true)
    backend.failNextRequest()
    let failedStart = try rpc.request(
      "turn/start",
      [
        "threadId": thread,
        "input": [
          ["type": "text", "text": "Test uncertain delivery without replay.", "text_elements": []]
        ],
      ])
    let failedID = try RouterJSON.text(RouterJSON.map(failedStart, "turn"), "id")
    let failedTurn = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
    #expect(failedTurn["status"] as? String == "failed")
    #expect(backend.requests(for: failedID).count == 1)
    backend.setTool("text(6 * 7);")
    provider.choose(provider.first.account.id)
    _ = try rpc.request(
      "turn/start",
      [
        "threadId": thread,
        "input": [
          [
            "type": "text", "text": "Start a new calculation after the failed turn.",
            "text_elements": [],
          ]
        ],
      ])
    let recovered = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
    let recoveryDetails = try RouterJSON.string(recovered)
    try #require(
      recovered["status"] as? String == "completed", "\(failures.messages), \(recoveryDetails)")
    let recoveredCalls = backend.requests(for: try RouterJSON.text(recovered, "id"))
    #expect(recoveredCalls.count == 2)
    #expect(recoveredCalls.allSatisfy { $0.account == provider.first.account.id })
    #expect(backend.requests(for: failedID).count == 1)
    backend.setTool(
      #"text(await tools.web__run({ search_query: [{ q: "turnrail synthetic search" }], response_length: "short" }));"#
    )
    let searchThread = try rpc.request(
      "thread/start",
      [
        "cwd": root.url.path, "ephemeral": true,
        "config": ["web_search": "live", "features.standalone_web_search": true],
      ])
    let searchID = try RouterJSON.text(RouterJSON.map(searchThread, "thread"), "id")
    _ = try rpc.request(
      "turn/start",
      [
        "threadId": searchID,
        "input": [["type": "text", "text": "Run the synthetic web search.", "text_elements": []]],
      ])
    let searchDone = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
    try #require(searchDone["status"] as? String == "completed", "\(failures.messages)")
    let searchCalls = backend.requests(for: try RouterJSON.text(searchDone, "id"))
    let searchOutputs = try searchCalls.flatMap { try RouterJSON.array($0.body.value, "input") }
      .filter { $0["type"] as? String == "custom_tool_call_output" }
    let searchOutputDetails = try RouterJSON.string(searchOutputs)
    #expect(
      try searchOutputs.contains { try RouterJSON.string($0).contains("SYNTHETIC_SEARCH_RESULT") },
      "\(searchOutputDetails); \(failures.messages)")
    try #require(searches.requests.count == 1)
    let searchRequest = searches.requests[0]
    #expect(
      searchRequest.value(forHTTPHeaderField: "Authorization")
        == "Bearer SYNTHETIC_NOT_SENT_TO_NETWORK")
    let searchMetadata = try RouterJSON.object(
      Data(#require(searchRequest.value(forHTTPHeaderField: "x-codex-turn-metadata")).utf8))
    #expect(searchMetadata["thread_id"] as? String == searchID)
    #expect(searchMetadata["turn_id"] as? String == searchDone["id"] as? String)
    #expect(searchCalls.allSatisfy { $0.account == provider.first.account.id })
    // If the replacement transport is also unavailable, stop before inference.
    // The Engine must not retry the failed turn or choose a different account.
    let opened = backend.openedAccounts.count
    backend.expireConnections()
    backend.allowNewConnections(false)
    _ = try rpc.request(
      "turn/start",
      [
        "threadId": searchID,
        "input": [
          ["type": "text", "text": "Test an unavailable connection.", "text_elements": []]
        ],
      ])
    let unavailable = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
    #expect(unavailable["status"] as? String == "failed")
    #expect(backend.requests(for: try RouterJSON.text(unavailable, "id")).isEmpty)
    #expect(backend.openedAccounts.count == opened + 1)
    #expect(backend.openedAccounts.last == provider.first.account.id)
    backend.allowNewConnections(true)
    // Terminal service failures stay visible after compaction and never cause
    // the official Engine to replay the inference or select another account.
    for (event, reason): ([String: Any], String) in [
      (
        ["type": "error", "status": 429, "error": ["type": "usage_limit_reached"]],
        "usage_limit_reached"
      ),
      (
        ["type": "response.failed", "response": ["error": ["code": "context_length_exceeded"]]],
        "context_length_exceeded"
      ),
      (
        [
          "type": "response.incomplete",
          "response": ["incomplete_details": ["reason": "max_output_tokens"]],
        ],
        "max_output_tokens"
      ),
      (
        [
          "type": "error",
          "error": ["type": "invalid_request_error", "code": "misalignment_policy_violation"],
        ],
        "misalignment_policy_violation"
      ),
      (
        [
          "type": "response.failed",
          "response": ["error": ["code": "misalignment_policy_violation"]],
        ],
        "misalignment_policy_violation"
      ),
    ] {
      backend.rejectNext(event)
      _ = try rpc.request(
        "turn/start",
        [
          "threadId": thread,
          "input": [
            ["type": "text", "text": "Test a terminal service failure.", "text_elements": []]
          ],
        ])
      let rejected = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
      #expect(rejected["status"] as? String == "failed")
      #expect(try RouterJSON.string(rejected).contains(reason))
      if reason == "misalignment_policy_violation" {
        let error = try RouterJSON.map(rejected, "error")
        #expect(error["codexErrorInfo"] as? String == "misalignmentPolicyViolation")
      }
      let rejectedCalls = backend.requests(for: try RouterJSON.text(rejected, "id"))
      #expect(rejectedCalls.count == 1)
      #expect(rejectedCalls.allSatisfy { $0.account == provider.first.account.id })
    }
    if let proof = ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_PROOF"] {
      try RouterJSON.writePrivate(
        RouterJSON.data([
          "code_mode", "account_switch", "title_routing", "approval_accept", "approval_decline",
          "no_replay", "compaction", "failure_recovery", "web_search", "connection_recovery",
        ]), to: URL(filePath: proof))
    }
  }
}

private final class FixtureFailures: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  var messages: [String] { lock.withLock { values } }
  func append(_ message: String) { lock.withLock { values.append(message) } }
}

private final class FixtureAccounts: RouterAccountProviding, @unchecked Sendable {
  let root: URL
  let first: RouterAccountSnapshot
  let second: RouterAccountSnapshot
  private let lock = NSLock()
  private var selected: UUID

  init(root: URL) throws {
    self.root = root
    let model: [String: Any] = [
      "slug": "gpt-5.6-luna", "display_name": "Fixture", "description": "Local synthetic model",
      "base_instructions": "Follow the user's request using the provided local fixture tools.",
      "default_reasoning_level": "low",
      "supported_reasoning_levels": [["effort": "low", "description": "Fixture"]],
      "shell_type": "shell_command", "visibility": "list", "supported_in_api": true, "priority": 0,
      "support_verbosity": false, "truncation_policy": ["mode": "tokens", "limit": 10000],
      "experimental_supported_tools": [], "input_modalities": ["text"], "context_window": 100000,
      "supports_search_tool": true,
    ]
    let credential = RouterCredential(
      accessToken: "SYNTHETIC_NOT_SENT_TO_NETWORK", accountID: "fixture", expiresAt: .distantFuture)
    first = RouterAccountSnapshot(
      account: try TurnrailAccount(id: UUID(), email: "first@example.com", planType: .pro),
      credential: credential, models: [model], usable: true, inspectedAt: Date())
    second = RouterAccountSnapshot(
      account: try TurnrailAccount(id: UUID(), email: "second@example.com", planType: .pro),
      credential: credential, models: [model], usable: true, inspectedAt: Date())
    selected = first.account.id
    for account in [first, second] {
      try RouterJSON.privateDirectory(
        root.appending(path: "accounts/\(account.account.id.uuidString.lowercased())"))
    }
  }

  func choose(_ id: UUID) { lock.withLock { selected = id } }
  func select(cwd: String) throws -> RouterAccountSnapshot {
    guard cwd == root.path else { throw RouterFailure("Unknown fixture folder.") }
    return try bound(lock.withLock { selected })
  }
  func bound(_ id: UUID) throws -> RouterAccountSnapshot {
    guard let account = [first, second].first(where: { $0.account.id == id }) else {
      throw RouterFailure("Unknown fixture account.")
    }
    return account
  }
  func commonCatalog() throws -> [String: Any] { ["models": first.models] }
}

private final class FixtureSearch: @unchecked Sendable {
  private let lock = NSLock()
  private var received: [URLRequest] = []
  var requests: [URLRequest] { lock.withLock { received } }
  func send(_ request: URLRequest) throws -> Data {
    try lock.withLock {
      received.append(request)
      return try RouterJSON.data(["output": "SYNTHETIC_SEARCH_RESULT", "results": []])
    }
  }
}

private final class FixtureModel: @unchecked Sendable {
  struct Request: Sendable {
    let account: UUID
    let body: RouterObject
    let turn: String
  }
  private let lock = NSLock()
  private var received: [Request] = []
  private var tools = Set<String>()
  private var toolSource = "text(6 * 7);"
  private var failNext = false
  private var rejection: RouterObject?
  private var epoch = 0
  private var opened: [UUID] = []
  private var acceptingConnections = true

  var connectionEpoch: Int { lock.withLock { epoch } }
  var openedAccounts: [UUID] { lock.withLock { opened } }
  func expireConnections() { lock.withLock { epoch += 1 } }
  func allowNewConnections(_ value: Bool) { lock.withLock { acceptingConnections = value } }
  func openConnection(account: UUID) -> (Int, Bool) {
    lock.withLock {
      opened.append(account)
      return (epoch, acceptingConnections)
    }
  }

  func setTool(_ source: String) { lock.withLock { toolSource = source } }
  func failNextRequest() { lock.withLock { failNext = true } }
  func rejectNext(_ event: [String: Any]) { lock.withLock { rejection = RouterObject(event) } }

  func requests(for turn: String) -> [Request] {
    lock.withLock { received.filter { $0.turn == turn } }
  }

  func response(_ data: Data, account: UUID) throws -> [Data] {
    try lock.withLock {
      let body = try RouterJSON.object(data)
      let metadata = try RouterRequest.metadata(body)
      let turn = try RouterJSON.text(metadata, "turn_id")
      received.append(Request(account: account, body: RouterObject(body), turn: turn))
      if let rejection {
        self.rejection = nil
        return [try RouterJSON.data(rejection.value)]
      }
      if failNext {
        failNext = false
        return []  // Simulate disconnection after the request reached the server.
      }
      let item: [String: Any]
      if metadata["request_kind"] as? String == "compaction" {
        item = [
          "type": "compaction", "encrypted_content": "SYNTHETIC_COMPACTION_SUMMARY",
        ]
      } else if metadata["thread_source"] as? String == "thread_title" {
        item = [
          "id": "title-item", "type": "message", "role": "assistant",
          "content": [["type": "output_text", "text": "Verify routing"]],
        ]
      } else if tools.insert(turn).inserted {
        item = [
          "id": "tool-" + turn, "type": "custom_tool_call", "name": "exec",
          "call_id": "call-" + turn, "input": toolSource,
        ]
      } else {
        item = [
          "id": "answer-" + turn, "type": "message", "role": "assistant",
          "content": [["type": "output_text", "text": "42"]],
        ]
      }
      let id = "fixture-response-\(received.count)"
      return try [
        ["type": "response.created", "response": ["id": id]],
        ["type": "response.output_item.done", "item": item],
        [
          "type": "response.completed",
          "response": [
            "id": id, "usage": ["input_tokens": 1, "output_tokens": 1, "total_tokens": 2],
          ],
        ],
      ].map(RouterJSON.data)
    }
  }
}

private final class FixtureUpstream: RouterUpstream, @unchecked Sendable {
  let generation = UUID().uuidString
  let accountID: UUID
  private let backend: FixtureModel
  private let epoch: Int
  private let available: Bool
  private var events: [Data] = []
  init(account: UUID, backend: FixtureModel) {
    accountID = account
    self.backend = backend
    (epoch, available) = backend.openConnection(account: account)
  }
  func checkConnection() throws {
    guard available, epoch == backend.connectionEpoch else {
      throw RouterTransportFailure(
        phase: .check, error: URLError(.networkConnectionLost), closeCode: .invalid)
    }
  }
  func send(_ data: Data) throws {
    guard epoch == backend.connectionEpoch else {
      throw RouterFailure("The idle fixture connection expired before sending.")
    }
    events = try backend.response(data, account: accountID)
  }
  func receive() throws -> Data {
    guard !events.isEmpty else { throw RouterFailure("No fixture event.") }
    return events.removeFirst()
  }
  func close() {}
}
