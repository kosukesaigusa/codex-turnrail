import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterAccountLifecycleTests {
  @Test
  func startupCatalogCachesOnlyCapabilitiesAndSelectionsStillReadQuota() throws {
    let fixture = try AccountInspectionFixture()
    fixture.change { $0.metadataFailure = .usage }
    let catalog = try RouterJSON.array(fixture.router.commonCatalog(), "models")
    #expect(try catalog.map { try RouterJSON.text($0, "slug") } == ["fixture"])
    #expect(fixture.calls == ["auth", "models", "auth", "models"])
    #expect(
      try fixture.router.select(cwd: fixture.root.url.path).account.id == fixture.accounts[0].id)
    #expect(fixture.calls == ["auth", "models", "auth", "models", "usage"])
    #expect(fixture.warnings == [.transport])
  }

  @Test
  func boundRequestsDoNotDependOnRepeatedAccountQuotaOrCatalogInspection() throws {
    let fixture = try AccountInspectionFixture()
    let selected = try fixture.router.select(cwd: fixture.root.url.path)
    let calls = fixture.calls
    fixture.change {
      $0.authenticationFails = true
      $0.metadataFailure = .usage
    }
    for elapsed in [61.0, 301.0, 1_801.0] {
      fixture.change { $0.now = fixture.started.addingTimeInterval(elapsed) }
      let bound = try fixture.router.bound(selected.account.id)
      #expect(bound === selected)
      try RouterModelCatalog.validate(["model": "fixture"], catalog: bound.models)
    }
    #expect(fixture.calls == calls)
  }

  @Test
  func webSearchContinuesWithTheValidatedBindingWhileInspectionIsUnavailable() throws {
    let fixture = try AccountInspectionFixture()
    let selected = try fixture.router.select(cwd: fixture.root.url.path)
    let runtime = try RouterRuntime(
      root: fixture.root.url, accounts: fixture.router,
      connect: { _, _ in fatalError("The search fixture must not connect to a model.") },
      search: { request in
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-1")
        #expect(
          request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == selected.credential.accountID)
        return try RouterJSON.data(["output": "result"])
      })
    defer { runtime.stop() }
    try runtime.ledger.bind("thread/turn", account: selected.account.id)
    fixture.change {
      $0.now = fixture.started.addingTimeInterval(120)
      $0.authenticationFails = true
      $0.metadataFailure = .models
    }
    let result = try runtime.webSearch(
      RouterJSON.data(["model": "fixture"]),
      headers: [
        "x-codex-turn-metadata": try RouterJSON.string([
          "thread_id": "thread", "turn_id": "turn",
        ])
      ])
    #expect(try RouterJSON.text(RouterJSON.object(result), "output") == "result")
    #expect(try runtime.ledger.bound("thread/turn") == selected.account.id)
    #expect(fixture.calls == ["auth", "models", "usage"])
  }

  @Test
  func nearExpiryRenewsOnlyAuthenticationAndTheNextSelectionStillChecksQuota() throws {
    let fixture = try AccountInspectionFixture()
    let selected = try fixture.router.select(cwd: fixture.root.url.path)
    fixture.change {
      $0.now = selected.credential.expiresAt.addingTimeInterval(-60)
      $0.metadataFailure = .usage
    }
    let renewed = try fixture.router.bound(selected.account.id)
    #expect(renewed.credential.accessToken == "synthetic-2")
    #expect(renewed.credential.accountID == selected.credential.accountID)
    #expect(renewed.credential.expiresAt > selected.credential.expiresAt)
    #expect(renewed.inspectedAt == selected.inspectedAt)
    #expect(fixture.calls == ["auth", "models", "usage", "auth"])
    #expect(try fixture.router.bound(selected.account.id) === renewed)
    #expect(try fixture.router.select(cwd: fixture.root.url.path).account.id == selected.account.id)
    #expect(fixture.calls.suffix(3) == ["auth", "models", "usage"])
    #expect(fixture.warnings == [.transport])
  }

  @Test
  func failedRenewalExpiredTokensAndWorkspaceChangesCannotReuseTheOldCredential() throws {
    for failure in 0..<3 {
      let fixture = try AccountInspectionFixture()
      let selected = try fixture.router.select(cwd: fixture.root.url.path)
      fixture.change {
        $0.now = selected.credential.expiresAt
        switch failure {
        case 0: $0.authenticationFails = true
        case 1: $0.expiry = selected.credential.expiresAt
        default: $0.workspace = "another-workspace"
        }
      }
      for _ in 0..<2 {
        #expect(throws: (any Error).self) { try fixture.router.bound(selected.account.id) }
      }
      let renewals = failure == 0 ? ["auth", "auth"] : ["auth"]
      #expect(fixture.calls == ["auth", "models", "usage"] + renewals)
    }
  }

  @Test
  func metadataRefreshFailureDoesNotPoisonAnExistingBindingOrSeedAnUnverifiedOne() throws {
    for failure in [AccountInspectionFixture.Failure.models, .authentication] {
      let fixture = try AccountInspectionFixture()
      let selected = try fixture.router.select(cwd: fixture.root.url.path)
      fixture.change {
        $0.now = fixture.started.addingTimeInterval(61)
        $0.authenticationFails = failure == .authentication
        $0.metadataFailure = failure
      }
      #expect(throws: AccountInspectionFixture.Failure.self) {
        try fixture.router.select(cwd: fixture.root.url.path)
      }
      let calls = fixture.calls
      #expect(try fixture.router.bound(selected.account.id) === selected)
      #expect(fixture.calls == calls)
      let cold = try fixture.makeRouter()
      #expect(throws: AccountInspectionFixture.Failure.self) {
        try cold.bound(selected.account.id)
      }
    }
  }

  @Test
  func removedOrReplacedIdentityIsRejectedWithoutContactingInspectionServices() throws {
    for replace in [false, true] {
      let fixture = try AccountInspectionFixture()
      let selected = try fixture.router.select(cwd: fixture.root.url.path)
      let accounts =
        replace
        ? [try TurnrailAccount(id: selected.account.id, email: "other@example.com", planType: .pro)]
        : []
      try fixture.save(accounts)
      #expect(throws: RouterFailure.self) { try fixture.router.bound(selected.account.id) }
      #expect(fixture.calls == ["auth", "models", "usage"])
    }
  }

  @Test
  func newTurnsRespectQuotaAndPriorityWithoutMovingAnExistingBinding() throws {
    let fixture = try AccountInspectionFixture()
    let first = try fixture.router.select(cwd: fixture.root.url.path)
    fixture.change {
      $0.exhausted.insert(first.credential.accountID)
    }
    let second = try fixture.router.select(cwd: fixture.root.url.path)
    #expect(second.account.id == fixture.accounts[1].id)
    let bound = try fixture.router.bound(first.account.id)
    #expect(bound.account.id == first.account.id)
    try RouterModelCatalog.validate(["model": "fixture"], catalog: bound.models)
    try fixture.save(fixture.accounts.reversed())
    #expect(try fixture.router.select(cwd: fixture.root.url.path).account.id == second.account.id)
    #expect(try fixture.router.bound(first.account.id).account.id == first.account.id)
  }

  @Test
  func freshSelectionCannotReplaceTheWorkspaceUsedByExistingTurns() throws {
    let fixture = try AccountInspectionFixture()
    let selected = try fixture.router.select(cwd: fixture.root.url.path)
    fixture.change {
      $0.now = fixture.started.addingTimeInterval(61)
      $0.workspace = "changed-workspace"
    }
    #expect(throws: RouterAuthenticationRejection.self) {
      try fixture.router.select(cwd: fixture.root.url.path)
    }
    #expect(throws: RouterFailure.self) { try fixture.router.bound(selected.account.id) }
    #expect(fixture.calls == ["auth", "models", "usage", "auth"])
  }

  @Test
  func confirmedRejectionsInvalidateBindingsUntilSuccessfulAuthentication() throws {
    for failure in 0..<4 {
      let fixture = try AccountInspectionFixture()
      let selected = try fixture.router.select(cwd: fixture.root.url.path)
      fixture.change {
        $0.now = fixture.started.addingTimeInterval(61)
        switch failure {
        case 0: $0.authenticationRejection = .unverifiedPolicy
        case 1: $0.loginRequired = true
        case 2: $0.metadataRejectsCredentials = true
        default: $0.quotaRejectsCredentials = true
        }
      }
      #expect(throws: (any Error).self) { try fixture.router.select(cwd: fixture.root.url.path) }
      #expect(throws: RouterFailure.self) { try fixture.router.bound(selected.account.id) }
      fixture.change {
        $0.authenticationRejection = nil
        $0.loginRequired = false
        $0.metadataRejectsCredentials = false
        $0.quotaRejectsCredentials = false
      }
      let verified = try fixture.router.select(cwd: fixture.root.url.path)
      #expect(verified.account.id == selected.account.id)
      #expect(try fixture.router.bound(selected.account.id) === verified)
    }
  }

  @Test(arguments: [false, true])
  func quotaWaitDoesNotBlockAnExistingBindingOrItsAuthenticationRenewal(renew: Bool) throws {
    let fixture = try AccountInspectionFixture()
    let selected = try fixture.router.select(cwd: fixture.root.url.path)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let selectionDone = DispatchSemaphore(value: 0)
    let boundDone = DispatchSemaphore(value: 0)
    let selectionQueue = DispatchQueue(label: "RouterAccountLifecycleTests.selection")
    let boundQueue = DispatchQueue(label: "RouterAccountLifecycleTests.bound")
    fixture.change {
      $0.metadataGate = (entered, release)
      $0.metadataFailure = .usage
    }
    selectionQueue.async {
      defer { selectionDone.signal() }
      do {
        #expect(
          try fixture.router.select(cwd: fixture.root.url.path).account.id == selected.account.id)
      } catch { Issue.record(error) }
    }
    #expect(entered.wait(timeout: .now() + 10) == .success)
    if renew { fixture.change { $0.now = selected.credential.expiresAt.addingTimeInterval(-60) } }
    boundQueue.async {
      defer { boundDone.signal() }
      do {
        let bound = try fixture.router.bound(selected.account.id)
        #expect(bound.account.id == selected.account.id)
        #expect((bound.credential.accessToken != selected.credential.accessToken) == renew)
      } catch { Issue.record(error) }
    }
    let completedBeforeRefresh = boundDone.wait(timeout: .now() + 10) == .success
    release.signal()
    #expect(selectionDone.wait(timeout: .now() + 5) == .success)
    if !completedBeforeRefresh { _ = boundDone.wait(timeout: .now() + 5) }
    #expect(completedBeforeRefresh)
  }

  @Test
  func consecutiveSelectionsAlwaysCheckQuotaWithoutRepeatingCapabilityReads() throws {
    let fixture = try AccountInspectionFixture()
    let first = try fixture.router.select(cwd: fixture.root.url.path)
    for _ in 0..<3 {
      #expect(try fixture.router.select(cwd: fixture.root.url.path) === first)
    }
    #expect(fixture.calls == ["auth", "models", "usage", "usage", "usage", "usage"])
    fixture.change { $0.exhausted.insert(first.credential.accountID) }
    #expect(
      try fixture.router.select(cwd: fixture.root.url.path).account.id == fixture.accounts[1].id)
    fixture.change { $0.exhausted.removeAll() }
    #expect(try fixture.router.select(cwd: fixture.root.url.path).account.id == first.account.id)
  }

  @Test
  func unknownQuotaKeepsPriorityAndDoesNotPoisonAValidBinding() throws {
    let fixture = try AccountInspectionFixture()
    let first = try fixture.router.select(cwd: fixture.root.url.path)
    fixture.change { $0.metadataFailure = .usage }
    #expect(try fixture.router.select(cwd: fixture.root.url.path) === first)
    #expect(try fixture.router.bound(first.account.id) === first)
    try fixture.save(fixture.accounts.reversed())
    #expect(
      try fixture.router.select(cwd: fixture.root.url.path).account.id == fixture.accounts[1].id)
    #expect(fixture.warnings == [.transport, .transport])
  }

  @Test
  func coldBindingRequiresCapabilitiesButNeverChecksQuota() throws {
    let fixture = try AccountInspectionFixture()
    fixture.change { $0.metadataFailure = .usage }
    #expect(try fixture.router.bound(fixture.accounts[0].id).account.id == fixture.accounts[0].id)
    #expect(fixture.calls == ["auth", "models"])
  }

  @Test
  func allConfirmedExhaustedAccountsRemainAnError() throws {
    let fixture = try AccountInspectionFixture()
    fixture.change { $0.exhausted = Set(fixture.accounts.map { $0.id.uuidString }) }
    #expect(throws: RouterFailure.self) { try fixture.router.select(cwd: fixture.root.url.path) }
    #expect(fixture.calls.filter { $0 == "usage" }.count == 2)
    #expect(fixture.warnings.isEmpty)
  }

  @Test
  func duplicatePromptHooksDoNotRepeatSelectionWithinTheSameTurn() throws {
    let fixture = try AccountInspectionFixture()
    let runtime = try RouterRuntime(
      root: fixture.root.url, accounts: fixture.router,
      connect: { _, _ in fatalError("The hook fixture must not connect to a model.") })
    defer { runtime.stop() }
    for turn in ["first", "first", "second"] {
      _ = try runtime.hook([
        "session_id": "thread", "turn_id": turn, "hook_event_name": "UserPromptSubmit",
        "cwd": fixture.root.url.path,
      ])
    }
    #expect(fixture.calls.filter { $0 == "usage" }.count == 2)
    #expect(try runtime.ledger.bound("thread/first") == fixture.accounts[0].id)
    #expect(try runtime.ledger.bound("thread/second") == fixture.accounts[0].id)
  }

}

private final class AccountInspectionFixture: @unchecked Sendable {
  enum Failure: Error { case authentication, usage, models }
  struct State {
    var now = Date(timeIntervalSince1970: 1_000)
    var authenticationFails = false
    var authenticationRejection: RouterAuthenticationRejection?
    var loginRequired = false
    var metadataRejectsCredentials = false
    var quotaRejectsCredentials = false
    var metadataFailure: Failure?
    var expiry: Date?
    var workspace: String?
    var exhausted = Set<String>()
    var metadataGate: (DispatchSemaphore, DispatchSemaphore)?
    var calls: [String] = []
    var warnings: [RouterQuotaUnavailable] = []
  }

  let root: RouterTestDirectory
  let accounts: [TurnrailAccount]
  let started = Date(timeIntervalSince1970: 1_000)
  private let lock = NSLock()
  private var state = State()
  private(set) var router: RouterAccounts!
  var calls: [String] { lock.withLock { state.calls } }
  var warnings: [RouterQuotaUnavailable] { lock.withLock { state.warnings } }

  init() throws {
    root = try RouterTestDirectory()
    accounts = try ["first@example.com", "second@example.com"].map {
      try TurnrailAccount(id: UUID(), email: $0, planType: .pro)
    }
    for account in accounts {
      try RouterJSON.privateDirectory(
        root.url.appending(path: "accounts/\(account.id.uuidString.lowercased())/auth-home"))
    }
    try save(accounts)
    router = try makeRouter()
  }

  func change(_ body: (inout State) -> Void) { lock.withLock { body(&state) } }

  func save(_ accounts: [TurnrailAccount]) throws {
    let state = AccountRegistryState(
      schemaVersion: AccountRegistryState.currentSchemaVersion, revision: 1, accounts: accounts,
      routing: AccountRoutingConfiguration(
        defaultAccountIDs: accounts.map(\.id), directoryRules: []))
    try RouterJSON.writePrivate(
      JSONEncoder().encode(state), to: root.url.appending(path: "state.json"))
  }

  func makeRouter() throws -> RouterAccounts {
    try RouterAccounts(
      root: root.url, engineVersion: "codex-cli 0.1.0",
      authenticate: { [unowned self] account, home, now in
        try self.lock.withLock {
          self.state.calls.append("auth")
          if let rejection = self.state.authenticationRejection { throw rejection }
          if self.state.loginRequired { throw RouterAccountUnavailable.loginRequired }
          if self.state.authenticationFails { throw Failure.authentication }
          #expect(home.lastPathComponent == "auth-home")
          return RouterCredential(
            accessToken: "synthetic-\(self.state.calls.filter { $0 == "auth" }.count)",
            accountID: self.state.workspace ?? account.id.uuidString,
            expiresAt: self.state.expiry ?? now.addingTimeInterval(3_600))
        }
      },
      get: { [unowned self] url, _ in
        #expect(url.path == "/backend-api/codex/models")
        return try self.lock.withLock {
          self.state.calls.append("models")
          if self.state.metadataRejectsCredentials { throw RouterAccountUnavailable.loginRequired }
          if self.state.metadataFailure == .models { throw Failure.models }
          return ["models": [["slug": "fixture"]]]
        }
      },
      readQuota: { [unowned self] credential, _ in
        let snapshot = self.lock.withLock {
          self.state.calls.append("usage")
          let snapshot = self.state
          self.state.metadataGate = nil
          return snapshot
        }
        if let (entered, release) = snapshot.metadataGate {
          entered.signal()
          guard release.wait(timeout: .now() + 10) == .success else {
            throw RouterFailure("Synthetic inspection gate timed out.")
          }
        }
        if snapshot.quotaRejectsCredentials { throw RouterAccountUnavailable.loginRequired }
        if snapshot.metadataFailure == .usage { return .unavailable(.transport) }
        return snapshot.exhausted.contains(credential.accountID) ? .exhausted : .available
      }, quotaWait: 2,
      reportQuotaUnavailable: { [unowned self] warning in
        self.lock.withLock { self.state.warnings.append(warning) }
      }, now: { [unowned self] in self.lock.withLock { self.state.now } })
  }
}
