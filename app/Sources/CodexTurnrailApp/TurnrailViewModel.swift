import AppKit
import CodexTurnrailCore
import SwiftUI

@MainActor
final class TurnrailViewModel: ObservableObject {
  struct AccountIssue: Equatable, Identifiable {
    enum Source: String, Equatable {
      case authentication
      case usage
    }

    let accountID: UUID
    let source: Source
    let details: String
    let recoveryAction: AccountRecoveryAction?

    var id: String {
      "\(accountID.uuidString):\(source.rawValue)"
    }

    var badgeTitle: String {
      if recoveryAction == .reauthenticate {
        return "Authentication expired"
      }
      switch source {
      case .authentication:
        return "Account error"
      case .usage:
        return "Usage error"
      }
    }

    var summary: String {
      if recoveryAction == .reauthenticate {
        return "The saved ChatGPT authentication token has expired."
      }
      switch source {
      case .authentication:
        return "The account could not be verified."
      case .usage:
        return "Usage data could not be refreshed."
      }
    }

    var canReauthenticate: Bool {
      recoveryAction == .reauthenticate
    }
  }

  enum AccountAuthStatus: Equatable {
    case checking
    case loggedOut
    case loggedIn
    case loginInProgress
    case failed(AccountIssue)

  }

  enum AccountUsageStatus: Equatable {
    case checking
    case available(AccountRateLimits)
    case failed(AccountIssue)
  }

  enum State: Equatable {
    case checking
    case ready(CompatibilityReport)
    case blocked(StatusNotice)
    case launched
  }

  enum LoginTarget: Equatable {
    case newAccount
    case account(UUID)
  }

  enum PrimaryAction: Equatable {
    case addAccount
    case assignAccount
    case signIn
    case openCodex
    case unavailable

    var title: String {
      switch self {
      case .addAccount: "Add Account"
      case .assignAccount: "Assign Account"
      case .signIn: "Sign In"
      case .openCodex, .unavailable: "Open Codex"
      }
    }
  }

  @Published private(set) var state: State = .checking
  @Published private(set) var registryState: AccountRegistryState = .empty {
    didSet { refreshRoutingScope() }
  }
  @Published var routingScope: AccountRoutingScope = .defaultRule {
    didSet { refreshRoutingScope() }
  }
  @Published private(set) var ruleAccountIDs: [UUID] = []
  @Published private(set) var displayedAccounts: [TurnrailAccount] = []
  @Published private(set) var accountError: String?
  @Published private(set) var registryLoadError: String?
  @Published private(set) var authStatusByAccountID: [UUID: AccountAuthStatus] = [:]
  @Published private(set) var usageStatusByAccountID: [UUID: AccountUsageStatus] = [:]
  @Published private(set) var lastUsedByAccountID: [UUID: AccountLastUsedStatus] = [:]
  @Published private(set) var isCodexRunning = false
  @Published private(set) var isRefreshingAccounts = false
  @Published private(set) var activeLogin: LoginTarget?
  @Published private(set) var isCancellingLogin = false
  @Published private(set) var isCompletingLogin = false
  @Published private(set) var removingAccountIDs = Set<UUID>()

  let appURL = URL(filePath: "/Applications/ChatGPT.app")
  private let commandExecutor: CommandExecutor
  private let loginExecutor: AccountLoginExecutor
  private let compatibilityProbe: (URL, URL) throws -> CompatibilityReport
  private let isApplicationRunning: () -> Bool
  private let identityReader: AccountIdentityReader
  private let usageReader: AccountUsageReader
  private let engineURLResult: Result<URL, Error>
  private let registryStoreResult: Result<AccountRegistryStore, Error>
  private var lastRefreshAt: Date?
  private var operationByAccountID: [UUID: UUID] = [:]
  private var loginTask: Task<Void, Never>?

  var isAddingAccount: Bool { activeLogin == .newAccount }
  var isSigningIn: Bool { activeLogin != nil }

  var primaryAction: PrimaryAction {
    guard registryLoadError == nil, case .ready = state else {
      return .unavailable
    }
    if registryState.accounts.isEmpty { return .addAccount }
    if registryState.routing.allAllowedAccountIDs.isEmpty { return .assignAccount }
    if isCodexRunning { return .unavailable }
    return canLaunch ? .openCodex : .signIn
  }

  var statusText: String {
    if registryLoadError != nil { return "Settings Error" }
    switch state {
    case .checking:
      return "Checking"
    case .blocked:
      return "Blocked"
    case .launched:
      return "Running"
    case .ready:
      if isCodexRunning { return "Running" }
      if registryState.accounts.isEmpty { return "No Accounts" }
      if registryState.routing.allAllowedAccountIDs.isEmpty { return "No Assignments" }
      return canLaunch ? "Ready" : "Sign-in Required"
    }
  }

  var statusNotice: StatusNotice? {
    if let registryLoadError {
      return StatusNotice(title: "Settings Error", message: registryLoadError, recovery: nil)
    }
    if case .blocked(let notice) = state { return notice }
    return nil
  }

  var canLaunch: Bool {
    guard case .ready = state, registryLoadError == nil, !isCodexRunning else {
      return false
    }
    return registryState.accounts.contains { account in
      registryState.routing.allAllowedAccountIDs.contains(account.id)
        && authStatusByAccountID[account.id] == .loggedIn
        && accountIssue(for: account)?.canReauthenticate != true
    }
  }

  convenience init() {
    let bundle = Bundle.main
    let engineURLResult = Result {
      try EnginePathResolver.resolve(
        isPackagedApp: bundle.bundleURL.pathExtension == "app",
        resourcesURL: bundle.resourceURL,
        environment: ProcessInfo.processInfo.environment
      )
    }
    let registryStoreResult = Result {
      AccountRegistryStore(rootURL: try TurnrailApplicationSupport.rootURL())
    }
    self.init(
      engineURLResult: engineURLResult,
      registryStoreResult: registryStoreResult,
      commandExecutor: .live,
      loginExecutor: .live,
      compatibilityProbe: { try CompatibilityProbe().probe(appURL: $0, engineURL: $1) },
      isApplicationRunning: {
        !NSRunningApplication.runningApplications(
          withBundleIdentifier: CodexCompatibilityContract.supported.bundleIdentifier
        ).isEmpty
      },
      identityReader: .live,
      usageReader: .live
    )
    refreshCompatibility()
    refreshApplicationState()
  }

  init(
    engineURLResult: Result<URL, Error>,
    registryStoreResult: Result<AccountRegistryStore, Error>,
    commandExecutor: CommandExecutor,
    loginExecutor: AccountLoginExecutor,
    compatibilityProbe: @escaping (URL, URL) throws -> CompatibilityReport,
    isApplicationRunning: @escaping () -> Bool,
    identityReader: AccountIdentityReader,
    usageReader: AccountUsageReader
  ) {
    self.engineURLResult = engineURLResult
    self.registryStoreResult = registryStoreResult
    self.commandExecutor = commandExecutor
    self.loginExecutor = loginExecutor
    self.compatibilityProbe = compatibilityProbe
    self.isApplicationRunning = isApplicationRunning
    self.identityReader = identityReader
    self.usageReader = usageReader
    do {
      registryState = try registryStoreResult.get().loadOrInitialize()
    } catch {
      registryLoadError = error.localizedDescription
      accountError = error.localizedDescription
    }
    refreshRoutingScope()
    refreshLastUsed()
  }

  func refreshApplicationState() {
    isCodexRunning = isApplicationRunning()
    if case .launched = state, !isCodexRunning {
      refreshCompatibility()
    }
  }

  func clearAccountError() {
    accountError = nil
  }

  func showAccountError(_ message: String) {
    accountError = message
  }

  @discardableResult
  func addAccount() -> Task<Void, Never>? {
    guard !isSigningIn, registryLoadError == nil else {
      return nil
    }
    activeLogin = .newAccount
    accountError = nil
    let task = Task {
      defer { finishLogin() }
      let accountID = UUID()
      var authenticationStarted = false
      do {
        try Task.checkCancellation()
        let command = try authenticationCommand(
          forAccountID: accountID,
          action: .login(expectedEmail: nil)
        )
        authenticationStarted = true
        let result = try await loginExecutor.execute(command)
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
          throw TurnrailViewModelError.commandFailed(
            operation: "Login",
            status: result.exitCode,
            output: commandOutput(result)
          )
        }
        guard let identity = try await readIdentity(forAccountID: accountID) else {
          throw TurnrailViewModelError.loginCompletedWithoutAccount
        }
        try Task.checkCancellation()
        registryState = try registryStoreResult.get().registerAccount(
          identity: identity,
          to: registryState,
          id: accountID
        )
        authStatusByAccountID[accountID] = .loggedIn
        isCompletingLogin = true
        await refreshUsage(forAccountID: accountID)
        accountError = nil
      } catch {
        let cleanupError = await cleanupTemporaryAccount(
          accountID: accountID,
          logout: authenticationStarted
        )
        if Task.isCancelled || error is CancellationError {
          accountError = cleanupError
        } else {
          accountError = [error.localizedDescription, cleanupError]
            .compactMap { $0 }
            .joined(separator: "\n")
        }
      }
    }
    loginTask = task
    return task
  }

  func cancelSignIn() {
    guard let loginTask, !isCancellingLogin, !isCompletingLogin else { return }
    isCancellingLogin = true
    loginTask.cancel()
  }

  private func finishLogin() {
    activeLogin = nil
    isCancellingLogin = false
    isCompletingLogin = false
    loginTask = nil
  }

  func monitorAccounts() async {
    while !Task.isCancelled {
      await refreshAccountData(at: Date())
      do {
        try await Task.sleep(for: .seconds(5))
      } catch {
        return
      }
    }
  }

  func monitorLastUsed() async {
    while !Task.isCancelled {
      refreshLastUsed()
      do {
        try await Task.sleep(for: .seconds(5))
      } catch {
        return
      }
    }
  }

  func refreshAccountData(at now: Date) async {
    refreshLastUsed()
    if let lastRefreshAt, (0..<60).contains(now.timeIntervalSince(lastRefreshAt)) {
      return
    }
    await refreshAllAuthStatuses(at: now)
  }

  func refreshAllAuthStatuses() async {
    await refreshAllAuthStatuses(at: Date())
  }

  private func refreshAllAuthStatuses(at now: Date) async {
    guard !isRefreshingAccounts else { return }
    isRefreshingAccounts = true
    lastRefreshAt = now
    refreshLastUsed()
    defer { isRefreshingAccounts = false }
    for account in registryState.accounts {
      guard !Task.isCancelled else { return }
      await refreshAuthStatus(for: account)
    }
  }

  func refreshAuthStatus(for account: TurnrailAccount) async {
    guard registryState.accounts.contains(where: { $0.id == account.id }),
      authStatusByAccountID[account.id] != .loginInProgress,
      !removingAccountIDs.contains(account.id)
    else { return }
    let operation = UUID()
    operationByAccountID[account.id] = operation
    if authStatusByAccountID[account.id] == nil { authStatusByAccountID[account.id] = .checking }
    if usageStatusByAccountID[account.id] == nil { usageStatusByAccountID[account.id] = .checking }
    do {
      let identity = try await readIdentity(forAccountID: account.id)
      guard operationByAccountID[account.id] == operation else { return }
      guard let identity else {
        authStatusByAccountID[account.id] = .loggedOut
        usageStatusByAccountID.removeValue(forKey: account.id)
        return
      }
      registryState = try registryStoreResult.get().updateIdentity(
        identity,
        for: account.id,
        in: registryState
      )
      authStatusByAccountID[account.id] = .loggedIn
      await refreshUsage(forAccountID: account.id)
    } catch {
      guard operationByAccountID[account.id] == operation else { return }
      authStatusByAccountID[account.id] = .failed(
        Self.accountIssue(accountID: account.id, source: .authentication, error: error)
      )
      usageStatusByAccountID.removeValue(forKey: account.id)
    }
  }

  @discardableResult
  func reauthenticate(accountID: UUID) -> Task<Void, Never>? {
    guard let account = registryState.accounts.first(where: { $0.id == accountID }) else {
      accountError = "Account \(accountID.uuidString) no longer exists."
      return nil
    }
    guard !isSigningIn,
      registryLoadError == nil,
      !removingAccountIDs.contains(account.id)
    else { return nil }
    activeLogin = .account(accountID)
    operationByAccountID[account.id] = UUID()
    authStatusByAccountID[account.id] = .loginInProgress
    usageStatusByAccountID.removeValue(forKey: account.id)
    let task = Task {
      defer { finishLogin() }
      do {
        try Task.checkCancellation()
        let command = try authenticationCommand(
          forAccountID: account.id,
          action: .login(expectedEmail: account.email)
        )
        let result = try await loginExecutor.execute(command)
        try Task.checkCancellation()
        guard result.exitCode == 0 else {
          throw TurnrailViewModelError.commandFailed(
            operation: "Login",
            status: result.exitCode,
            output: commandOutput(result)
          )
        }
        guard let identity = try await readIdentity(forAccountID: account.id) else {
          throw TurnrailViewModelError.loginCompletedWithoutAccount
        }
        try Task.checkCancellation()
        registryState = try registryStoreResult.get().updateIdentity(
          identity,
          for: account.id,
          in: registryState
        )
        authStatusByAccountID[account.id] = .loggedIn
        isCompletingLogin = true
        await refreshUsage(forAccountID: account.id)
      } catch {
        if Task.isCancelled || error is CancellationError {
          authStatusByAccountID.removeValue(forKey: account.id)
          let refresh = Task { await refreshAuthStatus(for: account) }
          await refresh.value
        } else {
          authStatusByAccountID[account.id] = .failed(
            Self.accountIssue(accountID: account.id, source: .authentication, error: error)
          )
        }
      }
    }
    loginTask = task
    return task
  }

  @discardableResult
  func remove(account: TurnrailAccount) -> Task<Void, Never>? {
    guard !removingAccountIDs.contains(account.id),
      authStatusByAccountID[account.id] != .loginInProgress
    else {
      return nil
    }
    removingAccountIDs.insert(account.id)
    operationByAccountID[account.id] = UUID()
    accountError = nil
    return Task {
      defer {
        removingAccountIDs.remove(account.id)
      }
      do {
        let command = try authenticationCommand(forAccountID: account.id, action: .logout)
        let result = try await executeInBackground(command)
        guard result.exitCode == 0 else {
          throw TurnrailViewModelError.commandFailed(
            operation: "Logout",
            status: result.exitCode,
            output: commandOutput(result)
          )
        }
        registryState = try registryStoreResult.get().removeAccount(
          id: account.id,
          from: registryState
        )
        authStatusByAccountID.removeValue(forKey: account.id)
        usageStatusByAccountID.removeValue(forKey: account.id)
        lastUsedByAccountID.removeValue(forKey: account.id)
        operationByAccountID.removeValue(forKey: account.id)
        try registryStoreResult.get().removeAuthHome(forAccountID: account.id)
      } catch {
        accountError = error.localizedDescription
      }
    }
  }

  private enum AuthenticationAction {
    case login(expectedEmail: String?)
    case logout
  }

  private func authenticationCommand(
    forAccountID accountID: UUID,
    action: AuthenticationAction
  ) throws -> AccountAuthenticationCommand {
    let engineURL = try engineURLResult.get()
    let authHomeURL = try registryStoreResult.get().ensureAuthHome(forAccountID: accountID)
    switch action {
    case .login(let expectedEmail):
      return AccountAuthenticationCommandFactory.makeLogin(
        engineURL: engineURL,
        authHomeURL: authHomeURL,
        expectedEmail: expectedEmail,
        inheritedEnvironment: ProcessInfo.processInfo.environment
      )
    case .logout:
      return AccountAuthenticationCommandFactory.makeLogout(
        engineURL: engineURL,
        authHomeURL: authHomeURL,
        inheritedEnvironment: ProcessInfo.processInfo.environment
      )
    }
  }

  private func readIdentity(forAccountID accountID: UUID) async throws
    -> ChatGPTAccountIdentity?
  {
    let authHomeURL = try registryStoreResult.get().ensureAuthHome(forAccountID: accountID)
    return try await identityReader.read(
      engineURL: engineURLResult.get(),
      authHomeURL: authHomeURL
    )
  }

  private func refreshUsage(forAccountID accountID: UUID) async {
    guard registryState.accounts.contains(where: { $0.id == accountID }),
      authStatusByAccountID[accountID] == .loggedIn,
      !removingAccountIDs.contains(accountID)
    else { return }
    let operation = UUID()
    operationByAccountID[accountID] = operation
    if usageStatusByAccountID[accountID] == nil { usageStatusByAccountID[accountID] = .checking }
    do {
      let authHomeURL = try registryStoreResult.get().ensureAuthHome(forAccountID: accountID)
      let rateLimits = try await usageReader.read(
        engineURL: engineURLResult.get(),
        authHomeURL: authHomeURL
      )
      guard operationByAccountID[accountID] == operation else { return }
      usageStatusByAccountID[accountID] = .available(rateLimits)
    } catch {
      guard operationByAccountID[accountID] == operation else { return }
      usageStatusByAccountID[accountID] = .failed(
        Self.accountIssue(accountID: accountID, source: .usage, error: error)
      )
    }
  }

  private func refreshLastUsed() {
    do {
      let reader = AccountLastUsedReader(rootURL: try registryStoreResult.get().rootURL)
      lastUsedByAccountID = Dictionary(
        uniqueKeysWithValues: registryState.accounts.map { ($0.id, reader.read(accountID: $0.id)) }
      )
    } catch {
      lastUsedByAccountID = Dictionary(
        uniqueKeysWithValues: registryState.accounts.map {
          ($0.id, .failed(error.localizedDescription))
        }
      )
    }
  }

  func accountIssue(for account: TurnrailAccount) -> AccountIssue? {
    if case .failed(let issue) = authStatusByAccountID[account.id] {
      return issue
    }
    if case .failed(let issue) = usageStatusByAccountID[account.id] {
      return issue
    }
    return nil
  }

  private static func accountIssue(
    accountID: UUID,
    source: AccountIssue.Source,
    error: Error
  ) -> AccountIssue {
    if let readerError = error as? AccountReaderError,
      case .serverError(let failure) = readerError
    {
      return AccountIssue(
        accountID: accountID,
        source: source,
        details: failure.diagnosticJSON,
        recoveryAction: failure.recoveryAction
      )
    }
    return AccountIssue(
      accountID: accountID,
      source: source,
      details: error.localizedDescription,
      recoveryAction: nil
    )
  }

  private func cleanupTemporaryAccount(accountID: UUID, logout: Bool) async -> String? {
    do {
      if logout {
        let command = try authenticationCommand(forAccountID: accountID, action: .logout)
        let result = try await executeInBackground(command)
        guard result.exitCode == 0 else {
          throw TurnrailViewModelError.commandFailed(
            operation: "Temporary account cleanup",
            status: result.exitCode,
            output: commandOutput(result)
          )
        }
      }
      try registryStoreResult.get().removeAuthHome(forAccountID: accountID)
      return nil
    } catch {
      return "Temporary account cleanup failed: \(error.localizedDescription)"
    }
  }

  private func commandOutput(_ result: CommandResult) -> String {
    (result.standardOutput + result.standardError)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func executeInBackground(
    _ command: AccountAuthenticationCommand
  ) async throws -> CommandResult {
    let executor = commandExecutor
    return try await Task.detached {
      try executor.execute(
        command.executableURL,
        arguments: command.arguments,
        environment: command.environment
      )
    }.value
  }

  private func refreshRoutingScope() {
    do {
      let ids = try registryState.routing.accountIDs(in: routingScope)
      var ordered: [TurnrailAccount] = []
      for id in ids {
        guard let account = registryState.accounts.first(where: { $0.id == id }) else {
          throw AccountRegistryError.unknownAccount(id)
        }
        ordered.append(account)
      }
      ruleAccountIDs = ids
      displayedAccounts = ordered
    } catch {
      accountError = error.localizedDescription
    }
  }

  private func updateRouting(
    _ change: (AccountRoutingConfiguration) throws -> AccountRoutingConfiguration
  ) {
    guard registryLoadError == nil else { return }
    do {
      registryState = try registryStoreResult.get().updateRouting(
        change(registryState.routing), in: registryState
      )
      accountError = nil
    } catch {
      accountError = error.localizedDescription
    }
  }

  func selectAccount(id: UUID, scope: AccountRoutingScope) {
    updateRouting { try $0.prioritizing(accountID: id, in: scope) }
  }

  func setAccountAllowed(id: UUID, allowed: Bool, scope: AccountRoutingScope) {
    updateRouting { try $0.settingAllowed(allowed, accountID: id, in: scope) }
  }

  func moveAccount(id: UUID, direction: AccountMoveDirection) {
    updateRouting { try $0.moving(accountID: id, direction: direction, in: routingScope) }
  }

  func chooseRoutingDirectory(replacing ruleID: UUID?) -> UUID? {
    guard registryLoadError == nil else { return nil }
    let panel = NSOpenPanel()
    panel.title = "Choose Folder"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    let id: UUID
    if let ruleID {
      id = ruleID
      updateRouting { try $0.changingDirectory(id: id, to: url) }
    } else {
      id = UUID()
      updateRouting { try $0.addingDirectory(url, id: id) }
    }
    if registryState.routing.directoryRules.contains(where: { $0.id == id }) {
      routingScope = .directory(id)
      return id
    }
    return nil
  }

  func removeRoutingDirectory(id: UUID) {
    if routingScope == .directory(id) { routingScope = .defaultRule }
    updateRouting { try $0.removingDirectory(id: id) }
  }

  @discardableResult
  func refreshCompatibility() -> StatusNotice {
    state = .checking

    do {
      let engineURL = try engineURLResult.get()
      let report = try compatibilityProbe(appURL, engineURL)
      let notice = StatusNotice.compatibility(report)
      state = report.isCompatible ? .ready(report) : .blocked(notice)
      return notice
    } catch {
      let notice = StatusNotice.compatibilityError(error)
      state = .blocked(notice)
      return notice
    }
  }

  func launchCodex() {
    guard canLaunch else {
      return
    }

    guard !isApplicationRunning() else {
      state = .blocked(
        StatusNotice(
          title: "ChatGPT Is Running",
          message: "Quit the running ChatGPT app before starting Turnrail mode.",
          recovery: nil)
      )
      return
    }

    do {
      let engineURL = try engineURLResult.get()
      let registryStore = try registryStoreResult.get()
      let command = LaunchCommandFactory.makeCodexTurnrailLaunch(
        appURL: appURL,
        engineURL: engineURL,
        turnrailRootURL: registryStore.rootURL
      )
      let result = try commandExecutor.execute(
        command.executableURL,
        arguments: command.arguments,
        environment: ProcessInfo.processInfo.environment
      )
      guard result.exitCode == 0 else {
        let message = result.standardError.trimmingCharacters(
          in: .whitespacesAndNewlines
        )
        state = .blocked(
          StatusNotice(
            title: "ChatGPT Launch Failed", message: message, recovery: nil))
        return
      }
      state = .launched
    } catch {
      state = .blocked(
        StatusNotice(
          title: "ChatGPT Launch Failed", message: error.localizedDescription, recovery: nil))
    }
  }
}

enum TurnrailViewModelError: LocalizedError {
  case commandFailed(operation: String, status: Int32, output: String)
  case loginCompletedWithoutAccount

  var errorDescription: String? {
    switch self {
    case .commandFailed(let operation, let status, let output):
      "\(operation) failed (exit \(status)): \(output)"
    case .loginCompletedWithoutAccount:
      "Login completed, but ChatGPT did not return an account."
    }
  }
}
