import Foundation

final class RouterHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) { completionHandler(nil) }

  func get(_ url: URL, credential: RouterCredential) throws -> [String: Any] {
    var request = URLRequest(url: url)
    request.allHTTPHeaderFields = credential.headers.merging([
      "Accept": "application/json", "User-Agent": "codex-turnrail/1",
    ]) { _, new in new }
    let (data, status) = try Self.exchange(request, maximumBytes: 8 * 1024 * 1024)
    if status == 401 { throw RouterAccountUnavailable.loginRequired }
    guard status == 200 else {
      throw RouterFailure("Account inspection failed (HTTP \(status)).")
    }
    return try RouterJSON.object(data)
  }

  /// A single bounded request; redirects, cookies, caching, and retries are disabled.
  static func exchange(_ request: URLRequest, maximumBytes: Int) throws -> (Data, Int) {
    let result = RouterHTTPResult(maximumBytes: maximumBytes)
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 30
    config.timeoutIntervalForResource = 60
    config.httpShouldSetCookies = false
    config.urlCache = nil
    let session = URLSession(configuration: config, delegate: result, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    session.dataTask(with: request).resume()
    guard result.ready.wait(timeout: .now() + 65) == .success else {
      throw RouterFailure("The account request timed out. No request was replayed.")
    }
    if result.error != nil {
      throw RouterFailure("The account request failed. No request was replayed.")
    }
    guard let response = result.response as? HTTPURLResponse else {
      throw RouterFailure("The account service returned no HTTP response.")
    }
    return (result.data, response.statusCode)
  }
}

private final class RouterHTTPResult: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let maximumBytes: Int
  let ready = DispatchSemaphore(value: 0)
  var data = Data()
  var response: URLResponse?
  var error: Error?
  init(maximumBytes: Int) { self.maximumBytes = maximumBytes }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    self.response = response
    completionHandler(response.expectedContentLength > maximumBytes ? .cancel : .allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
    guard data.count + chunk.count <= maximumBytes else {
      error = RouterFailure("The account response exceeded the supported size.")
      dataTask.cancel()
      return
    }
    data.append(chunk)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if self.error == nil { self.error = error }
    ready.signal()
  }
}

final class RouterAccountSnapshot: @unchecked Sendable {
  let account: TurnrailAccount
  let credential: RouterCredential
  let models: [[String: Any]]
  let inspectedAt: Date
  let usable: Bool

  init(
    account: TurnrailAccount, credential: RouterCredential, models: [[String: Any]], usable: Bool,
    inspectedAt: Date
  ) {
    self.account = account
    self.credential = credential
    self.models = models
    self.usable = usable
    self.inspectedAt = inspectedAt
  }
}

protocol RouterAccountProviding: Sendable {
  var root: URL { get }
  func select(cwd: String) throws -> RouterAccountSnapshot
  func bound(_ id: UUID) throws -> RouterAccountSnapshot
  func commonCatalog() throws -> [String: Any]
}

final class RouterAccounts: RouterAccountProviding, @unchecked Sendable {
  let root: URL
  let engine: URL
  private let http = RouterHTTP()
  private let lock = NSRecursiveLock()
  private var cache: [UUID: RouterAccountSnapshot] = [:]

  init(root: URL, engine: URL) {
    self.root = root
    self.engine = engine
  }

  func registry() throws -> AccountRegistryState {
    guard FileManager.default.fileExists(atPath: root.appending(path: "state.json").path) else {
      throw RouterFailure("The Turnrail account registry is missing.")
    }
    return try AccountRegistryStore(rootURL: root).loadOrInitialize()
  }

  func select(cwd: String) throws -> RouterAccountSnapshot {
    let state = try registry()
    let ordered = try RouterDirectory.accounts(cwd: cwd, routing: state.routing)
    guard !ordered.isEmpty else {
      throw RouterFailure("No accounts are allowed for this folder. Assign an account in Turnrail.")
    }
    for id in ordered {
      guard let account = state.accounts.first(where: { $0.id == id }) else {
        throw RouterFailure("The folder references an unknown account.")
      }
      do {
        let snapshot = try inspect(account)
        if snapshot.usable { return snapshot }
      } catch is RouterAccountUnavailable { continue }
    }
    throw RouterFailure(
      "All accounts allowed for this folder need sign-in or have exhausted their usage limits.")
  }

  func bound(_ id: UUID) throws -> RouterAccountSnapshot {
    guard let account = try registry().accounts.first(where: { $0.id == id }) else {
      throw RouterFailure("The account bound to this turn was removed. Start a new turn.")
    }
    // A running turn never silently changes accounts, even when its quota is exhausted.
    return try inspect(account)
  }

  func inspect(_ account: TurnrailAccount) throws -> RouterAccountSnapshot {
    try lock.withLock {
      if let saved = cache[account.id], saved.account == account,
        Date().timeIntervalSince(saved.inspectedAt) < 60,
        saved.credential.expiresAt.timeIntervalSinceNow > 60
      {
        return saved
      }
      let home = root.appending(path: "accounts/\(account.id.uuidString.lowercased())/auth-home")
      let credential = try inspectAuthentication(account, home: home)
      let usage = try http.get(
        URL(string: "https://chatgpt.com/backend-api/wham/usage")!, credential: credential)
      let usable = try Self.generalQuotaIsUsable(usage)
      let version = CodexCompatibilityContract.supported.cliVersion.replacingOccurrences(
        of: "codex-cli ", with: "")
      var components = URLComponents(string: "https://chatgpt.com/backend-api/codex/models")!
      components.queryItems = [URLQueryItem(name: "client_version", value: version)]
      let models = try RouterJSON.array(http.get(components.url!, credential: credential), "models")
      var slugs = Set<String>()
      for model in models {
        guard slugs.insert(try RouterJSON.text(model, "slug")).inserted else {
          throw RouterFailure("The account catalog contains duplicate models.")
        }
      }
      guard !models.isEmpty else {
        throw RouterFailure("The account returned an empty model catalog.")
      }
      let snapshot = RouterAccountSnapshot(
        account: account, credential: credential, models: models, usable: usable,
        inspectedAt: Date())
      cache[account.id] = snapshot
      return snapshot
    }
  }

  private func inspectAuthentication(_ account: TurnrailAccount, home: URL) throws
    -> RouterCredential
  {
    try AccountCredentialStore.withExclusiveAccess(to: home) {
      // The official Engine owns saved credentials and OAuth refreshes. Routine checks
      // never rewrite Keychain data or copy it into another Keychain item.
      let rpc = try OfficialEngineRPC(
        engine: engine, home: home, overrides: ["cli_auth_credentials_store=\"keyring\""])
      defer { rpc.close() }
      return try RouterAuthentication.read(
        expectedEmail: account.email, now: Date(), request: rpc.request)
    }
  }

  static func generalQuotaIsUsable(_ usage: [String: Any]) throws -> Bool {
    let limits = try RouterJSON.map(usage, "rate_limit")
    guard let allowed = limits["allowed"] as? Bool, let reached = limits["limit_reached"] as? Bool
    else {
      throw RouterFailure("The account did not report general usage availability.")
    }
    var exhausted = !allowed || reached
    for name in ["primary_window", "secondary_window"] {
      // The service contract permits absent/null windows, but not malformed windows.
      if limits[name] == nil || limits[name] is NSNull { continue }
      let window = try RouterJSON.map(limits, name)
      guard let number = window["used_percent"] as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID(),
        number.doubleValue.isFinite, (0...100).contains(number.doubleValue)
      else {
        throw RouterFailure("The account reported an invalid usage percentage.")
      }
      exhausted = exhausted || number.doubleValue == 100
    }
    return !exhausted
  }

  func commonCatalog() throws -> [String: Any] {
    let state = try registry()
    let assigned = state.accounts.filter { state.routing.allAllowedAccountIDs.contains($0.id) }
    var catalogs: [[[String: Any]]] = []
    for account in assigned {
      do { catalogs.append(try inspect(account).models) } catch is RouterAccountUnavailable {
        continue
      }
    }
    return ["models": try RouterModelCatalog.intersection(catalogs)]
  }
}

enum RouterModelCatalog {
  static func intersection(_ catalogs: [[[String: Any]]]) throws -> [[String: Any]] {
    guard var common = catalogs.first else {
      throw RouterFailure("No assigned account has an available model catalog.")
    }
    for catalog in catalogs.dropFirst() {
      common = try common.compactMap { model in
        let slug = try RouterJSON.text(model, "slug")
        guard let other = catalog.first(where: { $0["slug"] as? String == slug }) else {
          return nil
        }
        for field in [
          "shell_type", "apply_patch_tool_type", "tool_mode", "multi_agent_version",
          "multi_agent_reasoning_effort", "use_responses_lite", "node_repl_disabled",
          "node_repl_auto_review_required", "auto_review_model_override", "guardian", "comp_hash",
        ] {
          if try RouterJSON.data(["value": model[field] ?? NSNull()])
            != RouterJSON.data(["value": other[field] ?? NSNull()])
          {
            return nil
          }
        }
        var merged = model
        for field in [
          "supported_reasoning_levels", "input_modalities", "service_tiers",
          "additional_speed_tiers",
          "experimental_supported_tools",
        ] {
          if model[field] == nil && other[field] == nil { continue }
          guard let left = model[field] as? [Any], let right = other[field] as? [Any] else {
            throw RouterFailure("Model catalogs disagree on \(field).")
          }
          merged[field] = try left.filter { item in
            // Descriptive text is not a capability; compare the protocol identifier.
            func identifier(_ value: Any) throws -> Data {
              if let object = value as? [String: Any] {
                for key in ["effort", "id"] {
                  if let id = object[key] as? String { return Data(id.utf8) }
                }
              }
              return try JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
            }
            let id = try identifier(item)
            return try right.contains { try identifier($0) == id }
          }
        }
        if let modalities = merged["input_modalities"] as? [Any], modalities.isEmpty { return nil }
        if let levels = merged["supported_reasoning_levels"] as? [[String: Any]] {
          let bothUnspecified =
            (model["supported_reasoning_levels"] as? [Any])?.isEmpty == true
            && (other["supported_reasoning_levels"] as? [Any])?.isEmpty == true
          guard !levels.isEmpty || bothUnspecified else { return nil }
          if let selected = merged["default_reasoning_level"] as? String,
            !levels.isEmpty, !levels.contains(where: { $0["effort"] as? String == selected })
          {
            merged["default_reasoning_level"] = try RouterJSON.text(levels[0], "effort")
          }
        }
        for field in [
          "supports_personality", "supports_parallel_tool_calls", "supports_image_detail_original",
          "support_verbosity", "supports_search_tool", "supports_experimental_context",
          "supports_reasoning_summary_parameter",
        ] {
          if missing(model[field]) && missing(other[field]) { continue }
          guard let left = model[field] as? NSNumber, let right = other[field] as? NSNumber,
            CFGetTypeID(left) == CFBooleanGetTypeID(),
            CFGetTypeID(right) == CFBooleanGetTypeID()
          else { return nil }
          merged[field] = left.boolValue && right.boolValue
        }
        for field in [
          "context_window", "max_context_window", "auto_compact_token_limit",
          "effective_context_window_percent",
        ] {
          if missing(model[field]) && missing(other[field]) { continue }
          guard let left = model[field] as? NSNumber, let right = other[field] as? NSNumber,
            CFGetTypeID(left) != CFBooleanGetTypeID(),
            CFGetTypeID(right) != CFBooleanGetTypeID(),
            let leftValue = Int(exactly: left.doubleValue),
            let rightValue = Int(exactly: right.doubleValue), leftValue > 0, rightValue > 0
          else { return nil }
          merged[field] = min(leftValue, rightValue)
        }
        if let selected = merged["default_service_tier"] as? String,
          let tiers = merged["service_tiers"] as? [[String: Any]],
          !tiers.contains(where: { $0["id"] as? String == selected })
        {
          merged.removeValue(forKey: "default_service_tier")
        }
        if model["visibility"] as? String != other["visibility"] as? String {
          merged["visibility"] = "hide"
        }
        return merged
      }
    }
    guard !common.isEmpty else { throw RouterFailure("Assigned accounts have no common models.") }
    return common
  }

  private static func missing(_ value: Any?) -> Bool { value == nil || value is NSNull }

  static func validate(_ request: [String: Any], catalog: [[String: Any]]) throws {
    let slug = try RouterJSON.text(request, "model")
    guard let model = catalog.first(where: { $0["slug"] as? String == slug }) else {
      throw RouterFailure(
        "This model is not available for the selected account. Choose a common model or change the folder priority."
      )
    }
    if let reasoning = request["reasoning"] as? [String: Any],
      let effort = reasoning["effort"] as? String
    {
      let levels = try RouterJSON.array(model, "supported_reasoning_levels")
      guard levels.contains(where: { $0["effort"] as? String == effort }) else {
        throw RouterFailure("This reasoning effort is not available for the selected account.")
      }
    }
    if let tier = request["service_tier"] as? String, tier != "auto" {
      let tiers = try RouterJSON.array(model, "service_tiers")
      guard tiers.contains(where: { $0["id"] as? String == tier }) else {
        throw RouterFailure("This service tier is not available for the selected account.")
      }
    }
  }
}
