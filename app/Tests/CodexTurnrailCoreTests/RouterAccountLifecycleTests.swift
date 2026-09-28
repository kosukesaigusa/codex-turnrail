import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterAccountLifecycleTests {
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
    #expect(fixture.calls == ["auth", "usage", "models"])
  }

  @Test
  func nearExpiryRenewsOnlyAuthenticationAndDoesNotMarkQuotaAsFresh() throws {
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
    #expect(fixture.calls == ["auth", "usage", "models", "auth"])
    #expect(try fixture.router.bound(selected.account.id) === renewed)
    #expect(throws: AccountInspectionFixture.Failure.self) {
      try fixture.router.select(cwd: fixture.root.url.path)
    }
    #expect(fixture.calls.suffix(2) == ["auth", "usage"])
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
      #expect(fixture.calls == ["auth", "usage", "models"] + renewals)
    }
  }

  @Test
  func metadataRefreshFailureDoesNotPoisonAnExistingBindingOrSeedAnUnverifiedOne() throws {
    for failure in [AccountInspectionFixture.Failure.usage, .models, .authentication] {
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
      #expect(fixture.calls == ["auth", "usage", "models"])
    }
  }

  @Test
  func newTurnsRespectQuotaAndPriorityWithoutMovingAnExistingBinding() throws {
    let fixture = try AccountInspectionFixture()
    let first = try fixture.router.select(cwd: fixture.root.url.path)
    fixture.change {
      $0.now = fixture.started.addingTimeInterval(61)
      $0.exhausted.insert(first.credential.accountID)
    }
    let second = try fixture.router.select(cwd: fixture.root.url.path)
    #expect(second.account.id == fixture.accounts[1].id)
    let bound = try fixture.router.bound(first.account.id)
    #expect(bound.account.id == first.account.id)
    #expect(!bound.usable)
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
    #expect(fixture.calls == ["auth", "usage", "models", "auth"])
  }

  @Test
  func confirmedRejectionsInvalidateBindingsUntilSuccessfulAuthentication() throws {
    for failure in 0..<3 {
      let fixture = try AccountInspectionFixture()
      let selected = try fixture.router.select(cwd: fixture.root.url.path)
      fixture.change {
        $0.now = fixture.started.addingTimeInterval(61)
        switch failure {
        case 0: $0.authenticationRejection = .unverifiedPolicy
        case 1: $0.loginRequired = true
        default: $0.metadataRejectsCredentials = true
        }
      }
      #expect(throws: (any Error).self) { try fixture.router.select(cwd: fixture.root.url.path) }
      #expect(throws: RouterFailure.self) { try fixture.router.bound(selected.account.id) }
      fixture.change {
        $0.authenticationRejection = nil
        $0.loginRequired = false
        $0.metadataRejectsCredentials = false
      }
      let verified = try fixture.router.select(cwd: fixture.root.url.path)
      #expect(verified.account.id == selected.account.id)
      #expect(try fixture.router.bound(selected.account.id) === verified)
    }
  }

  @Test
  func slowSelectionRefreshDoesNotBlockAnotherTurnsValidBinding() throws {
    let fixture = try AccountInspectionFixture()
    let selected = try fixture.router.select(cwd: fixture.root.url.path)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let selectionDone = DispatchSemaphore(value: 0)
    let boundDone = DispatchSemaphore(value: 0)
    fixture.change {
      $0.now = fixture.started.addingTimeInterval(61)
      $0.metadataGate = (entered, release)
      $0.metadataFailure = .usage
    }
    DispatchQueue.global().async {
      defer { selectionDone.signal() }
      #expect(throws: AccountInspectionFixture.Failure.self) {
        try fixture.router.select(cwd: fixture.root.url.path)
      }
    }
    #expect(entered.wait(timeout: .now() + 2) == .success)
    DispatchQueue.global().async {
      defer { boundDone.signal() }
      do { #expect(try fixture.router.bound(selected.account.id) === selected) } catch {
        Issue.record(error)
      }
    }
    let completedBeforeRefresh = boundDone.wait(timeout: .now() + 2) == .success
    release.signal()
    #expect(selectionDone.wait(timeout: .now() + 5) == .success)
    if !completedBeforeRefresh { _ = boundDone.wait(timeout: .now() + 5) }
    #expect(completedBeforeRefresh)
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
    var metadataFailure: Failure?
    var expiry: Date?
    var workspace: String?
    var exhausted = Set<String>()
    var metadataGate: (DispatchSemaphore, DispatchSemaphore)?
    var calls: [String] = []
  }

  let root: RouterTestDirectory
  let accounts: [TurnrailAccount]
  let started = Date(timeIntervalSince1970: 1_000)
  private let lock = NSLock()
  private var state = State()
  private(set) var router: RouterAccounts!
  var calls: [String] { lock.withLock { state.calls } }

  init() throws {
    root = try RouterTestDirectory()
    accounts = try ["first@example.com", "second@example.com"].map {
      try TurnrailAccount(id: UUID(), email: $0, planType: .pro)
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
      get: { [unowned self] url, credential in
        let operation = url.path == "/backend-api/wham/usage" ? "usage" : "models"
        let snapshot = self.lock.withLock {
          self.state.calls.append(operation)
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
        if snapshot.metadataRejectsCredentials { throw RouterAccountUnavailable.loginRequired }
        if operation == "usage" {
          if snapshot.metadataFailure == .usage { throw Failure.usage }
          let exhausted = snapshot.exhausted.contains(credential.accountID)
          return ["rate_limit": ["allowed": !exhausted, "limit_reached": exhausted]]
        }
        if snapshot.metadataFailure == .models { throw Failure.models }
        return ["models": [["slug": "fixture"]]]
      }, now: { [unowned self] in self.lock.withLock { self.state.now } })
  }
}
