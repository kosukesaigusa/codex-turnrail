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
    let data: Data
    let status: Int
    do {
      (data, status) = try Self.exchange(
        request, maximumBytes: 8 * 1024 * 1024, deadline: .now() + 65)
    } catch {
      let operation: String
      switch url.path {
      case "/backend-api/wham/usage": operation = "usage"
      case "/backend-api/codex/models": operation = "model catalog"
      default: operation = "metadata"
      }
      throw RouterFailure("Account \(operation) inspection: \(error.localizedDescription)")
    }
    if status == 401 { throw RouterAccountUnavailable.loginRequired }
    guard status == 200 else {
      throw RouterFailure("Account inspection failed (HTTP \(status)).")
    }
    return try RouterJSON.object(data)
  }

  /// A single bounded request; redirects, cookies, caching, and retries are disabled.
  static func exchange(
    _ request: URLRequest, maximumBytes: Int, deadline: DispatchTime
  ) throws -> (Data, Int) {
    let started = DispatchTime.now()
    guard deadline > started else { throw RouterHTTPDeadlineExceeded() }
    let remaining = Double(deadline.uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000
    let result = RouterHTTPResult(maximumBytes: maximumBytes)
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = min(30, remaining)
    config.timeoutIntervalForResource = min(60, remaining)
    config.httpShouldSetCookies = false
    config.urlCache = nil
    let session = URLSession(configuration: config, delegate: result, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    session.dataTask(with: request).resume()
    guard result.ready.wait(timeout: deadline) == .success else {
      throw RouterHTTPDeadlineExceeded()
    }
    if let error = result.error {
      let cause = error as NSError
      if cause.domain == NSURLErrorDomain && cause.code == NSURLErrorTimedOut {
        throw RouterHTTPDeadlineExceeded()
      }
      throw RouterInspectionFailure.transport(error)
    }
    guard let response = result.response as? HTTPURLResponse else {
      throw RouterFailure("The account service returned no HTTP response.")
    }
    return (result.data, response.statusCode)
  }
}

struct RouterHTTPDeadlineExceeded: LocalizedError {
  var errorDescription: String? { "The HTTP request timed out. No request was replayed." }
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
  init(
    account: TurnrailAccount, credential: RouterCredential, models: [[String: Any]],
    inspectedAt: Date
  ) {
    self.account = account
    self.credential = credential
    self.models = models
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
  private let modelsURL: URL
  private let authenticate: (TurnrailAccount, URL, Date) throws -> RouterCredential
  private let get: (URL, RouterCredential) throws -> [String: Any]
  private let readQuota: (RouterCredential, DispatchTime) throws -> RouterQuotaAvailability
  private let quotaWait: TimeInterval
  private let reportQuotaUnavailable: (RouterQuotaUnavailable) -> Void
  private let now: () -> Date
  private let lock = NSRecursiveLock()
  private let cacheLock = NSLock()
  private var cache: [UUID: RouterAccountSnapshot] = [:]
  private var rejected = Set<UUID>()

  convenience init(root: URL, engine: URL, engineVersion: String) throws {
    try self.init(
      root: root, engineVersion: engineVersion,
      authenticate: { account, home, now in
        try AccountCredentialStore.withExclusiveAccess(to: home) {
          // Only the official Engine reads and refreshes saved credentials.
          let rpc = try OfficialEngineRPC(
            engine: engine, home: home, overrides: ["cli_auth_credentials_store=\"keyring\""])
          defer { rpc.close() }
          return try RouterAuthentication.read(
            expectedEmail: account.email, now: now, request: rpc.request)
        }
      }, get: RouterHTTP().get,
      readQuota: { credential, deadline in
        try RouterQuotaReader.read(
          url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
          credential: credential, deadline: deadline)
      }, quotaWait: 2,
      reportQuotaUnavailable: { reason in
        let message =
          "Quota inspection unavailable [\(reason.diagnostic)]. "
          + "Continuing with the validated assigned account.\n"
        try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
      }, now: Date.init)
  }

  init(
    root: URL, engineVersion: String,
    authenticate: @escaping (TurnrailAccount, URL, Date) throws -> RouterCredential,
    get: @escaping (URL, RouterCredential) throws -> [String: Any],
    readQuota: @escaping (RouterCredential, DispatchTime) throws -> RouterQuotaAvailability,
    quotaWait: TimeInterval,
    reportQuotaUnavailable: @escaping (RouterQuotaUnavailable) -> Void,
    now: @escaping () -> Date
  ) throws {
    guard quotaWait.isFinite && quotaWait > 0 else {
      throw RouterFailure("The quota inspection budget must be positive and finite.")
    }
    self.root = root
    self.authenticate = authenticate
    self.get = get
    self.readQuota = readQuota
    self.quotaWait = quotaWait
    self.reportQuotaUnavailable = reportQuotaUnavailable
    self.now = now
    modelsURL = try Self.modelCatalogURL(engineVersion: engineVersion)
  }

  static func modelCatalogURL(engineVersion: String) throws -> URL {
    let prefix = "codex-cli "
    guard engineVersion.hasPrefix(prefix) else {
      throw RouterFailure("The installed Engine returned an unrecognized version.")
    }
    let version = String(engineVersion.dropFirst(prefix.count))
    guard version.range(of: #"^[0-9][0-9A-Za-z.+-]*$"#, options: .regularExpression) != nil else {
      throw RouterFailure("The installed Engine returned an invalid version.")
    }
    var components = URLComponents(string: "https://chatgpt.com/backend-api/codex/models")!
    components.queryItems = [URLQueryItem(name: "client_version", value: version)]
    return components.url!
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
    var quotaBudget = RouterQuotaBudget(seconds: quotaWait)
    for id in ordered {
      guard let account = state.accounts.first(where: { $0.id == id }) else {
        throw RouterFailure("The folder references an unknown account.")
      }
      do {
        let snapshot = try inspect(account)
        // Optional quota HTTP runs after required validation releases its lock.
        let availability = try quotaBudget.read { deadline in
          try readQuota(snapshot.credential, deadline)
        }
        guard snapshot.credential.expiresAt > now() else {
          throw RouterAccountUnavailable.loginRequired
        }
        switch availability {
        case .available: return snapshot
        case .exhausted: continue
        case .unavailable(let reason):
          reportQuotaUnavailable(reason)
          return snapshot
        }
      } catch let error as RouterAccountUnavailable {
        if case .loginRequired = error { cacheLock.withLock { _ = rejected.insert(id) } }
        continue
      }
    }
    throw RouterFailure(
      "All accounts allowed for this folder need sign-in or have exhausted their usage limits.")
  }

  func bound(_ id: UUID) throws -> RouterAccountSnapshot {
    guard let account = try registry().accounts.first(where: { $0.id == id }) else {
      throw RouterFailure("The account bound to this turn was removed. Start a new turn.")
    }
    // A slow selection refresh must not hold up another turn's valid binding.
    if let saved = try cachedBinding(account),
      saved.credential.expiresAt.timeIntervalSince(now()) > 60
    {
      return saved
    }
    return try lock.withLock {
      // A cold process must establish identity, workspace policy, and catalog first.
      guard let saved = try cachedBinding(account) else { return try inspect(account) }
      let timestamp = now()
      // Quota and catalogs guide selection. They are not periodic prerequisites for
      // continuing an established binding; the model service still enforces access.
      if saved.credential.expiresAt.timeIntervalSince(timestamp) > 60 { return saved }
      let credential = try validatedCredential(account, at: timestamp)
      let updated = RouterAccountSnapshot(
        account: account, credential: credential, models: saved.models,
        inspectedAt: saved.inspectedAt)
      cacheLock.withLock { cache[id] = updated }
      return updated
    }
  }

  func inspect(_ account: TurnrailAccount) throws -> RouterAccountSnapshot {
    try lock.withLock {
      do {
        let timestamp = now()
        let cached = cacheLock.withLock {
          rejected.contains(account.id) ? nil : cache[account.id]
        }
        if let saved = cached,
          saved.account == account,
          timestamp.timeIntervalSince(saved.inspectedAt) < 60,
          saved.credential.expiresAt.timeIntervalSince(timestamp) > 60
        {
          return saved
        }
        let credential = try validatedCredential(account, at: timestamp)
        let models = try validatedModels(credential)
        let snapshot = RouterAccountSnapshot(
          account: account, credential: credential, models: models,
          inspectedAt: timestamp)
        cacheLock.withLock {
          cache[account.id] = snapshot
          rejected.remove(account.id)
        }
        return snapshot
      } catch let error as RouterAccountUnavailable {
        if case .loginRequired = error { cacheLock.withLock { _ = rejected.insert(account.id) } }
        throw error
      }
    }
  }

  private func cachedBinding(_ account: TurnrailAccount) throws -> RouterAccountSnapshot? {
    try cacheLock.withLock {
      guard !rejected.contains(account.id) else {
        throw RouterFailure(
          "The bound account requires authentication validation. Start a new turn.")
      }
      guard let saved = cache[account.id] else { return nil }
      guard saved.account.email == account.email else {
        throw RouterFailure("The account bound to this turn changed identity. Start a new turn.")
      }
      return saved
    }
  }

  private func validatedCredential(_ account: TurnrailAccount, at timestamp: Date) throws
    -> RouterCredential
  {
    let home = root.appending(path: "accounts/\(account.id.uuidString.lowercased())/auth-home")
    do {
      let credential = try authenticate(account, home, timestamp)
      if let saved = cacheLock.withLock({ cache[account.id] }) {
        guard saved.account.email == account.email,
          saved.credential.accountID == credential.accountID
        else { throw RouterAuthenticationRejection.workspaceChanged }
      }
      guard credential.expiresAt > now() else { throw RouterAccountUnavailable.loginRequired }
      return credential
    } catch let error as RouterAccountUnavailable {
      if case .loginRequired = error { cacheLock.withLock { _ = rejected.insert(account.id) } }
      throw error
    } catch let error as RouterAuthenticationRejection {
      cacheLock.withLock { _ = rejected.insert(account.id) }
      throw error
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
      do {
        // Cache verified capabilities only. Each selection reads quota separately.
        catalogs.append(try inspect(account).models)
      } catch is RouterAccountUnavailable {
        continue
      }
    }
    return ["models": try RouterModelCatalog.intersection(catalogs)]
  }

  private func validatedModels(_ credential: RouterCredential) throws -> [[String: Any]] {
    let models = try RouterJSON.array(get(modelsURL, credential), "models")
    var slugs = Set<String>()
    for model in models {
      guard slugs.insert(try RouterJSON.text(model, "slug")).inserted else {
        throw RouterFailure("The account catalog contains duplicate models.")
      }
    }
    guard !models.isEmpty else {
      throw RouterFailure("The account returned an empty model catalog.")
    }
    guard credential.expiresAt > now() else { throw RouterAccountUnavailable.loginRequired }
    return models
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
