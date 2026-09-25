import Foundation

final class RouterRuntime: @unchecked Sendable {
  let accounts: any RouterAccountProviding
  let ledger: RouterLedger
  let listener: RouterListener
  let sessionDirectory: URL
  let secret = UUID().uuidString + UUID().uuidString
  private let hookLock = NSLock()
  private let connect: @Sendable (RouterAccountSnapshot, [String: String]) -> any RouterUpstream
  private let search: @Sendable (URLRequest) throws -> Data
  private let reportFailure: @Sendable (String) -> Void
  private let transportLog: RouterTransportLog

  convenience init(root: URL, engine: URL, engineVersion: String) throws {
    try self.init(
      root: root,
      accounts: RouterAccounts(root: root, engine: engine, engineVersion: engineVersion),
      connect: { RouterWebSocket(account: $0, headers: $1) })
  }

  init(
    root: URL, accounts: any RouterAccountProviding,
    connect: @escaping @Sendable (RouterAccountSnapshot, [String: String]) -> any RouterUpstream,
    search: @escaping @Sendable (URLRequest) throws -> Data = { try RouterSearch.send($0) },
    reportFailure: @escaping @Sendable (String) -> Void = { _ in }
  ) throws {
    self.accounts = accounts
    self.connect = connect
    self.search = search
    self.reportFailure = reportFailure
    let storage = root.appending(path: "router")
    ledger = try RouterLedger(root: storage)
    transportLog = RouterTransportLog(root: storage)
    sessionDirectory = storage.appending(path: "sessions/\(UUID().uuidString)")
    try RouterJSON.privateDirectory(sessionDirectory)
    listener = try RouterListener()
    try RouterJSON.writePrivate(
      RouterJSON.data(["port": listener.port, "secret": secret]),
      to: sessionDirectory.appending(path: "endpoint.json"))
  }

  func start() { listener.start { [weak self] in self?.handle($0) } }

  func stop() {
    listener.stop()
    // Only ephemeral endpoint/catalog files; conversation recovery state is retained.
    try? FileManager.default.removeItem(at: sessionDirectory)
  }

  func configuration(engine: URL, home: URL, executable: URL) throws -> [String] {
    let catalog = sessionDirectory.appending(path: "models.json")
    try RouterJSON.writePrivate(RouterJSON.data(accounts.commonCatalog()), to: catalog)
    let command = [executable.path, "hook", sessionDirectory.path].map(RouterJSON.shellQuote)
      .joined(separator: " ")
    var overrides = [
      "model_provider=\"openai\"",
      "openai_base_url=\"http://127.0.0.1:\(listener.port)/\(secret)/v1\"",
      "features.hooks=true",
      "model_catalog_json=" + RouterJSON.quote(catalog.path),
      "features.remote_models=false",
    ]
    for event in ["UserPromptSubmit", "PreCompact", "Stop"] {
      overrides.append(
        "hooks.\(event)=[{hooks=[{type=\"command\",command=\(RouterJSON.quote(command)),timeout=90}]}]"
      )
    }
    let rpc = try OfficialEngineRPC(engine: engine, home: home, overrides: overrides)
    defer { rpc.close() }
    let result = try rpc.request("hooks/list", ["cwds": [home.path]])
    let entries = try RouterJSON.array(result, "data")
    let hooks = try entries.flatMap { try RouterJSON.array($0, "hooks") }.filter {
      $0["command"] as? String == command
    }
    guard hooks.count == 3 else {
      throw RouterFailure("The official Engine did not load all three Turnrail hooks.")
    }
    let trusted = try hooks.map { hook in
      let key = try RouterJSON.text(hook, "key")
      let hash = try RouterJSON.text(hook, "currentHash")
      return "\(RouterJSON.quote(key))={trusted_hash=\(RouterJSON.quote(hash))}"
    }
    // Hook state is merged across config layers by the official Engine. Quoting the
    // entire TOML table also preserves dots inside its opaque hook identifiers.
    overrides.append("hooks.state={" + trusted.joined(separator: ",") + "}")
    return overrides
  }

  func registerTitle(_ thread: [String: Any]) throws {
    let cwd = try RouterDirectory.canonical(RouterJSON.text(thread, "cwd")).path
    let account = try accounts.select(cwd: cwd)
    try ledger.registerTitle(
      thread: RouterJSON.text(thread, "id"), cwd: cwd, account: account.account.id)
  }

  func hook(_ event: [String: Any]) throws -> [String: Any] {
    try hookLock.withLock {
      let thread = try RouterJSON.text(event, "session_id")
      let turn = try RouterJSON.text(event, "turn_id")
      let key = try RouterLedger.key(thread, turn)
      switch try RouterJSON.text(event, "hook_event_name") {
      case "Stop": try ledger.stop(thread, turn: turn)
      case "PreCompact":
        if try ledger.bound(key) == nil {
          try ledger.bind(key, account: ledger.completedAccount(thread))
        }
      case "UserPromptSubmit":
        // Spawned agents carry their identity in hooks, but the exact parent turn
        // arrives with model metadata. Bind them there instead of reselecting a folder.
        if event["agent_id"] != nil {
          _ = try RouterJSON.text(event, "agent_id")
          return ["continue": true]
        }
        if try ledger.bound(key) == nil {
          let account = try accounts.select(cwd: RouterJSON.text(event, "cwd"))
          try ledger.bind(key, account: account.account.id)
          try recordLastUsed(account.account.id)
        }
      default: throw RouterFailure("Unexpected routing hook event.")
      }
      return ["continue": true]
    }
  }

  private func recordLastUsed(_ id: UUID) throws {
    let file = accounts.root.appending(
      path: "accounts/\(id.uuidString.lowercased())/last-used.json")
    var timestamp = Int64(Date().timeIntervalSince1970)
    if FileManager.default.fileExists(atPath: file.path) {
      let previous = try RouterJSON.object(Data(contentsOf: file))
      guard previous["schemaVersion"] as? Int == 1,
        let account = previous["accountId"] as? String, UUID(uuidString: account) == id,
        let recorded = previous["startedAtUnixSeconds"] as? Int64
      else { throw RouterFailure("Invalid Last used record.") }
      timestamp = max(timestamp, recorded)
    }
    try RouterJSON.writePrivate(
      RouterJSON.data([
        "schemaVersion": 1, "accountId": id.uuidString.lowercased(),
        "startedAtUnixSeconds": timestamp,
      ]), to: file)
  }

  private func handle(_ socket: RouterSocket) {
    do {
      let request = try socket.request()
      if request.method == "POST", request.path == "/\(secret)/hook" {
        guard let raw = request.headers["content-length"], let size = Int(raw),
          (1...16384).contains(size)
        else {
          throw RouterFailure("Invalid hook request size.")
        }
        let event = try RouterJSON.object(socket.read(size))
        do { try socket.reply(status: 200, body: hook(event)) } catch {
          reportFailure("Hook: " + error.localizedDescription)
          try socket.reply(
            status: 200, body: ["continue": false, "stopReason": error.localizedDescription])
        }
        return
      }
      if request.method == "POST", request.path == "/\(secret)/v1/alpha/search" {
        guard let raw = request.headers["content-length"], let size = Int(raw),
          (1...RouterSearch.maximumBytes).contains(size)
        else { throw RouterFailure("Invalid web search request size.") }
        try socket.reply(
          status: 200, data: webSearch(socket.read(size), headers: request.headers))
        return
      }
      guard request.path == "/\(secret)/v1/responses", request.method == "GET" else {
        try socket.reply(
          status: 403,
          body: ["error": ["message": "Turnrail requires a supported, bound Engine request."]])
        return
      }
      try socket.upgrade(request)
      route(socket, headers: request.headers)
    } catch {
      reportFailure("Local request: " + error.localizedDescription)
      // Never print HTTP headers, request bodies, or upstream errors containing credentials.
      try? socket.reply(
        status: 400, body: ["error": ["message": "Turnrail rejected an invalid local request."]])
    }
  }

  func webSearch(_ data: Data, headers: [String: String]) throws -> Data {
    guard data.count <= RouterSearch.maximumBytes,
      let rawMetadata = headers["x-codex-turn-metadata"]
    else { throw RouterFailure("Web search requires bounded input and turn metadata.") }
    let metadata = try RouterJSON.object(Data(rawMetadata.utf8))
    let key = try RouterLedger.key(
      RouterJSON.text(metadata, "thread_id"), RouterJSON.text(metadata, "turn_id"))
    // MCP metadata omits parent_turn_id. The preceding model request must already
    // have established the child or ordinary turn's immutable account binding.
    guard let accountID = try ledger.bound(key) else {
      throw RouterFailure("Web search requires an existing model-turn account binding.")
    }
    let body = try RouterJSON.object(data)
    let account = try accounts.bound(accountID)
    try RouterModelCatalog.validate(body, catalog: account.models)
    let fingerprint = try RouterJSON.hash(
      RouterJSON.data(["kind": "web_search", "turn": key, "body": body]))
    try ledger.begin(fingerprint, turn: key)
    do {
      let response = try search(
        RouterSearch.request(body: data, headers: headers, account: account))
      guard response.count <= RouterSearch.maximumBytes,
        try RouterJSON.object(response)["output"] is String
      else { throw RouterFailure("Web search returned an invalid response.") }
      try ledger.finish(fingerprint, turn: key)
      return response
    } catch {
      try ledger.fail(key)
      throw error
    }
  }

  private func route(_ downstream: RouterSocket, headers: [String: String]) {
    let messages = RouterMessages()
    messages.start(downstream)
    var upstream: (any RouterUpstream)?
    var currentTurn: String?
    var progress: RouterRequestProgress?
    defer {
      messages.stop()
      upstream?.close()
    }
    do {
      while let raw = messages.next() {
        currentTurn = nil
        progress = nil
        let body = try RouterJSON.object(raw)
        let metadata = try RouterRequest.metadata(body)
        let thread = try RouterJSON.text(metadata, "thread_id")
        let (input, previous) = try RouterRequest.expanded(body, thread: thread, ledger: ledger)
        if metadata["request_kind"] as? String == "prewarm" {
          guard body["generate"] as? Bool == false else {
            throw RouterFailure("Prewarm cannot perform inference.")
          }
          let id = "turnrail-prewarm-" + UUID().uuidString
          try ledger.saveHistory(
            id: id, value: RouterRequest.history(body, thread: thread, output: []))
          try downstream.frame(
            RouterJSON.data(["type": "response.created", "response": ["id": id]]))
          try downstream.frame(
            RouterJSON.data([
              "type": "response.completed",
              "response": [
                "id": id, "usage": ["input_tokens": 0, "output_tokens": 0, "total_tokens": 0],
              ],
            ]))
          continue
        }
        let (key, accountID) = try RouterRequest.binding(metadata, ledger: ledger)
        currentTurn = key
        let account = try accounts.bound(accountID)
        try RouterModelCatalog.validate(body, catalog: account.models)
        let connection = try readyConnection(
          upstream, account: account, headers: headers, messages: messages)
        let reused = upstream?.generation == connection.generation
        upstream = connection
        let fingerprint = try RouterRequest.fingerprint(body, input: input, turn: key)
        let payload = RouterRequest.payload(
          body, input: input, previous: previous, account: accountID,
          generation: connection.generation)
        try ledger.begin(fingerprint, turn: key)
        guard
          let kind = RouterTransportObservation.Kind(
            rawValue: try RouterJSON.text(metadata, "request_kind"))
        else { throw RouterFailure("Unsupported inference request kind.") }
        let data = try RouterJSON.data(payload)
        progress = RouterRequestProgress(
          kind: kind, connectionReused: reused, requestBytes: data.count)
        try connection.send(data)
        var output: [[String: Any]] = []
        while true {
          let rawEvent = try connection.receive()
          let event = try RouterJSON.object(rawEvent)
          let type = try RouterJSON.text(event, "type")
          progress?.received(type: type)
          if ["error", "response.failed", "response.incomplete"].contains(type) {
            let failure = try RouterServiceFailure(event: event)
            if failure.isWebSocketConnectionLimit, progress?.snapshot().receivedEvents == 1 {
              // The service explicitly rejected this request before any response.
              // Let the Engine retry it once; closing both sockets forces a new
              // generation with full known history and the same account binding.
              try ledger.rejectConnectionLimit(fingerprint, turn: key)
              try downstream.frame(RouterJSON.data(RouterServiceFailure.connectionLimitRetryEvent))
              currentTurn = nil
              return
            }
            throw failure
          }
          if type == "response.output_item.done" {
            output.append(try RouterJSON.map(event, "item"))
          }
          if type == "response.completed" {
            let response = try RouterJSON.map(event, "response")
            var history = try RouterRequest.history(body, thread: thread, output: output)
            history["account"] = accountID.uuidString.lowercased()
            history["generation"] = connection.generation
            // Commit history before acknowledging completion to the Engine.
            try ledger.complete(
              fingerprint, turn: key, response: RouterJSON.text(response, "id"),
              history: history)
          }
          try downstream.frame(rawEvent)
          if type == "response.completed" {
            currentTurn = nil
            break
          }
        }
      }
    } catch {
      let reported: Error
      if var failure = error as? RouterTransportFailure {
        failure.request = progress?.snapshot()
        do { failure.reference = try transportLog.record(failure) } catch {
          failure.diagnosticWriteFailed = true
        }
        reported = failure
      } else {
        reported = error
      }
      reportFailure("Model routing: " + reported.localizedDescription)
      if let currentTurn { try? ledger.fail(currentTurn) }
      let code: String
      if let failure = error as? RouterServiceFailure, failure.isMisalignmentPolicyViolation {
        // Preserve the official Engine's safety-stop classification. A generic
        // routing error hides the precaution from the desktop client.
        code = "misalignment_policy_violation"
      } else {
        code = "turnrail_routing_stopped"
      }
      try? downstream.frame(
        RouterJSON.data([
          // A terminal request error must not trigger the Engine's transport retry
          // policy, which can permanently disable WebSockets for the task.
          "type": "error", "status": 400,
          "error": [
            "type": "invalid_request_error", "code": code,
            "message": reported.localizedDescription,
          ],
        ]))
    }
  }

  private func readyConnection(
    _ current: (any RouterUpstream)?, account: RouterAccountSnapshot,
    headers: [String: String], messages: RouterMessages
  ) throws -> any RouterUpstream {
    if let current, current.accountID == account.account.id {
      do {
        try current.checkConnection()
        return current
      } catch let failure as RouterTransportFailure where failure.phase == .check {
        // No inference has been sent. Replace only this account's transport,
        // once; the new generation expands any previous_response_id locally.
        reportFailure("Reconnecting before sending [\(failure.diagnostic)].")
        current.close()
      }
    }
    let connection = connect(account, headers)
    try messages.attach(connection)
    try connection.checkConnection()
    return connection
  }
}
