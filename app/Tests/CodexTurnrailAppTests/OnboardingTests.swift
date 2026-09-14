import CodexTurnrailCore
import Foundation
import Testing

@testable import CodexTurnrailApp

@MainActor
struct OnboardingTests {
  @Test(.timeLimit(.minutes(1)))
  func cancellingAccountAdditionCleansItsCredentialsAndAllowsRetry() async throws {
    let fixture = try OnboardingFixture()
    defer { fixture.remove() }
    let gate = LoginGate()
    let model = fixture.model(
      login: AccountLoginExecutor { try await gate.run($0) },
      identity: fixture.identityReader
    )
    let before = model.registryState
    let first = try #require(model.addAccount())
    await gate.waitUntilStarted()
    #expect(model.isAddingAccount)
    #expect(model.addAccount() == nil)
    model.cancelSignIn()
    #expect(model.isCancellingLogin)
    await first.value
    #expect(!model.isSigningIn)
    #expect(model.accountError == nil)
    #expect(model.registryState == before)
    let cancelledCommand = try #require(await gate.commands.first)
    let cancelledHome = try #require(cancelledCommand.environment["CODEX_HOME"])
    #expect(!FileManager.default.fileExists(atPath: cancelledHome))
    #expect(fixture.logouts.homes == [cancelledHome])

    let retry = try #require(model.addAccount())
    await retry.value
    #expect(model.registryState.accounts.count == 1)
    #expect(model.registryState.routing.allAllowedAccountIDs.isEmpty)
    #expect(model.accountError == nil)
    #expect(!model.isSigningIn)
    let commands = await gate.commands
    #expect(commands.count == 2)
    #expect(commands[0].environment["CODEX_HOME"] != commands[1].environment["CODEX_HOME"])
  }

  @Test(.timeLimit(.minutes(1)))
  func cancellationAfterBrowserCompletionDoesNotRegisterTheTemporaryAccount() async throws {
    try await checkCancellationDuringIdentityRead(readFails: false)
  }

  @Test(.timeLimit(.minutes(1)))
  func cancellationDuringAFailedIdentityReadDoesNotRegisterTheTemporaryAccount() async throws {
    try await checkCancellationDuringIdentityRead(readFails: true)
  }

  private func checkCancellationDuringIdentityRead(readFails: Bool) async throws {
    let fixture = try OnboardingFixture()
    defer { fixture.remove() }
    let identityGate = PendingIdentity()
    let model = fixture.model(
      login: .immediateSuccess,
      identity: AccountIdentityReader { _, _ in try await identityGate.read() }
    )
    let task = try #require(model.addAccount())
    await identityGate.waitUntilStarted()
    model.cancelSignIn()
    if readFails {
      await identityGate.fail()
    } else {
      await identityGate.complete(
        try ChatGPTAccountIdentity(email: "new@example.com", planType: .pro))
    }
    await task.value
    #expect(model.registryState.accounts.isEmpty)
    #expect(try fixture.store.loadOrInitialize().accounts.isEmpty)
    #expect(fixture.logouts.homes.count == 1)
    #expect(model.accountError == nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func cancellingReauthenticationPreservesTheAccountAndAssignmentsAndCanRetry() async throws {
    let fixture = try OnboardingFixture()
    defer { fixture.remove() }
    var state = try fixture.store.registerAccount(
      identity: ChatGPTAccountIdentity(email: "account@example.com", planType: .pro),
      to: fixture.store.loadOrInitialize()
    )
    let account = try #require(state.accounts.first)
    state = try fixture.store.updateRouting(
      state.routing.settingAllowed(true, accountID: account.id, in: .defaultRule),
      in: state
    )
    let gate = LoginGate()
    let model = fixture.model(
      login: AccountLoginExecutor { try await gate.run($0) },
      identity: fixture.identityReader
    )
    let task = try #require(model.reauthenticate(accountID: account.id))
    await gate.waitUntilStarted()
    #expect(model.addAccount() == nil)
    #expect(model.reauthenticate(accountID: account.id) == nil)
    model.cancelSignIn()
    await task.value
    #expect(model.registryState == state)
    #expect(try fixture.store.loadOrInitialize() == state)
    #expect(fixture.logouts.homes.isEmpty)
    #expect(!model.isSigningIn)
    let retry = try #require(model.reauthenticate(accountID: account.id))
    await retry.value
    #expect(model.authStatusByAccountID[account.id] == .loggedIn)
    #expect(model.registryState == state)
    #expect(
      await gate.commands.allSatisfy {
        $0.environment["CODEX_TURNRAIL_EXPECTED_EMAIL"] == "account@example.com"
      })
  }

  @Test
  func setupProgressesOnlyAfterExplicitAccountAssignment() async throws {
    let fixture = try OnboardingFixture()
    defer { fixture.remove() }
    let model = fixture.model(login: .immediateSuccess, identity: fixture.identityReader)
    let check = model.refreshCompatibility()
    #expect(check.title == "Compatible")
    #expect(model.primaryAction == .addAccount)
    #expect(!model.canLaunch)
    let login = try #require(model.addAccount())
    await login.value
    #expect(model.primaryAction == .assignAccount)
    #expect(!model.canLaunch)
    let account = try #require(model.registryState.accounts.first)
    model.setAccountAllowed(id: account.id, allowed: true, scope: .defaultRule)
    #expect(model.primaryAction == .openCodex)
    #expect(model.canLaunch)
    model.setAccountAllowed(id: account.id, allowed: false, scope: .defaultRule)
    #expect(model.primaryAction == .assignAccount)
  }

  @Test
  func incompatibleCodexBlocksSetupActionsAndReturnsRecovery() throws {
    let fixture = try OnboardingFixture()
    defer { fixture.remove() }
    let model = TurnrailViewModel(
      engineURLResult: .success(URL(filePath: "/unused-test-engine")),
      registryStoreResult: .success(fixture.store),
      commandExecutor: CommandExecutor { _, _, _ in
        throw CompatibilityProbeError.engineUnavailable("/unused-test-engine")
      },
      loginExecutor: .immediateSuccess,
      compatibilityProbe: { _, _ in
        throw CompatibilityProbeError.appBundleMissing("/Applications/ChatGPT.app")
      },
      isApplicationRunning: { false },
      identityReader: fixture.identityReader,
      usageReader: AccountUsageReader { _, _ in AccountRateLimits(buckets: []) }
    )
    let check = model.refreshCompatibility()
    #expect(check.title == "ChatGPT Not Found")
    #expect(check.recovery == .installation)
    #expect(model.statusNotice == check)
    #expect(model.primaryAction == .unavailable)
    #expect(!model.canLaunch)
  }

  @Test
  func anAlreadyRunningCodexStillAllowsSetupButCannotLaunchTwice() async throws {
    let fixture = try OnboardingFixture()
    defer { fixture.remove() }
    let model = TurnrailViewModel(
      engineURLResult: .success(URL(filePath: "/unused-test-engine")),
      registryStoreResult: .success(fixture.store),
      commandExecutor: CommandExecutor { _, _, _ in
        Issue.record("A second official app must not be launched")
        return CommandResult(exitCode: 1, standardOutput: "", standardError: "Not allowed")
      },
      loginExecutor: .immediateSuccess,
      compatibilityProbe: { _, _ in supportedCompatibilityReport() },
      isApplicationRunning: { true },
      identityReader: fixture.identityReader,
      usageReader: AccountUsageReader { _, _ in AccountRateLimits(buckets: []) }
    )
    model.refreshCompatibility()
    model.refreshApplicationState()
    #expect(model.primaryAction == .addAccount)
    let login = try #require(model.addAccount())
    await login.value
    #expect(model.primaryAction == .assignAccount)
    let account = try #require(model.registryState.accounts.first)
    model.setAccountAllowed(id: account.id, allowed: true, scope: .defaultRule)
    #expect(model.primaryAction == .unavailable)
    #expect(!model.canLaunch)
    model.launchCodex()
  }

  @Test
  func assignedButSignedOutAccountsLeadToSignIn() async throws {
    let fixture = try OnboardingFixture()
    defer { fixture.remove() }
    let model = fixture.model(login: .immediateSuccess, identity: fixture.identityReader)
    let login = try #require(model.addAccount())
    await login.value
    let account = try #require(model.registryState.accounts.first)
    model.setAccountAllowed(id: account.id, allowed: true, scope: .defaultRule)
    let signedOut = fixture.model(
      login: .immediateSuccess, identity: AccountIdentityReader { _, _ in nil })
    await signedOut.refreshAllAuthStatuses()
    #expect(signedOut.primaryAction == .signIn)
    #expect(!signedOut.canLaunch)
  }
}

func supportedCompatibilityReport() -> CompatibilityReport {
  let contract = CodexCompatibilityContract.supported
  return CompatibilityReport(
    installed: CodexInstallation(
      bundleIdentifier: contract.bundleIdentifier,
      appVersion: contract.appVersion,
      appBuild: contract.appBuild,
      cliVersion: contract.cliVersion
    ),
    engineVersion: contract.cliVersion,
    mismatches: []
  )
}

extension AccountLoginExecutor {
  fileprivate static let immediateSuccess = Self { _ in
    CommandResult(exitCode: 0, standardOutput: "", standardError: "")
  }
}

@MainActor
private struct OnboardingFixture {
  let root: URL
  let store: AccountRegistryStore
  let logouts = LogoutCalls()

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    store = AccountRegistryStore(rootURL: root)
    _ = try store.loadOrInitialize()
  }

  var identityReader: AccountIdentityReader {
    AccountIdentityReader { _, _ in
      try ChatGPTAccountIdentity(email: "account@example.com", planType: .pro)
    }
  }

  func model(login: AccountLoginExecutor, identity: AccountIdentityReader) -> TurnrailViewModel {
    let logouts = logouts
    let model = TurnrailViewModel(
      engineURLResult: .success(URL(filePath: "/unused-test-engine")),
      registryStoreResult: .success(store),
      commandExecutor: CommandExecutor { _, arguments, environment in
        #expect(arguments.first == "logout")
        #expect(environment["CODEX_TURNRAIL_ROOT"] == nil)
        logouts.record(try #require(environment["CODEX_HOME"]))
        return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
      },
      loginExecutor: login,
      compatibilityProbe: { _, _ in supportedCompatibilityReport() },
      isApplicationRunning: { false },
      identityReader: identity,
      usageReader: AccountUsageReader { _, _ in AccountRateLimits(buckets: []) }
    )
    model.refreshCompatibility()
    return model
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class LogoutCalls: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  var homes: [String] { lock.withLock { values } }
  func record(_ home: String) { lock.withLock { values.append(home) } }
}

private actor LoginGate {
  private(set) var commands: [AccountAuthenticationCommand] = []
  private var started: CheckedContinuation<Void, Never>?

  func run(_ command: AccountAuthenticationCommand) async throws -> CommandResult {
    commands.append(command)
    started?.resume()
    started = nil
    if commands.count == 1 { try await Task.sleep(for: .seconds(60)) }
    return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
  }

  func waitUntilStarted() async {
    if !commands.isEmpty { return }
    await withCheckedContinuation { started = $0 }
  }
}

private actor PendingIdentity {
  private var requested = false
  private var started: CheckedContinuation<Void, Never>?
  private var result: CheckedContinuation<ChatGPTAccountIdentity, Error>?

  func read() async throws -> ChatGPTAccountIdentity {
    requested = true
    started?.resume()
    started = nil
    return try await withCheckedThrowingContinuation { result = $0 }
  }

  func waitUntilStarted() async {
    if requested { return }
    await withCheckedContinuation { started = $0 }
  }

  func complete(_ identity: ChatGPTAccountIdentity) {
    result?.resume(returning: identity)
    result = nil
  }

  func fail() {
    result?.resume(throwing: AccountReaderError.invalidResponse)
    result = nil
  }
}
