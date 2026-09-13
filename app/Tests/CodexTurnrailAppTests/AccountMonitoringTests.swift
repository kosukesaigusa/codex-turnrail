import CodexTurnrailCore
import Foundation
import Testing

@testable import CodexTurnrailApp

@MainActor
struct AccountMonitoringTests {
  @Test
  func ignoresAnOldIdentityReadThatFinishesAfterReauthentication() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let gate = IdentityGate()
    let model = TurnrailViewModel(
      engineURLResult: .success(URL(filePath: "/unused-test-engine")),
      registryStoreResult: .success(fixture.store),
      commandExecutor: CommandExecutor { _, _, _ in
        CommandResult(exitCode: 0, standardOutput: "", standardError: "")
      },
      identityReader: AccountIdentityReader { _, _ in try await gate.read() },
      usageReader: AccountUsageReader { _, _ in try usage(used: 10) }
    )
    let pending = Task { await model.refreshAllAuthStatuses() }
    await gate.waitUntilRequested()
    let login = try #require(model.reauthenticate(accountID: fixture.account.id))
    await login.value
    await gate.complete()
    await pending.value
    #expect(model.registryState.accounts == [fixture.account])
    #expect(model.authStatusByAccountID[fixture.account.id] == .loggedIn)
    #expect(try fixture.store.loadOrInitialize().accounts == [fixture.account])
  }

  @Test
  func refreshesUsageAtTheIntervalAndManuallyAndReplacesFailures() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let reads = UsageSequence()
    let model = fixture.model(usageReader: AccountUsageReader { _, _ in try await reads.read() })
    let start = Date(timeIntervalSince1970: 1_789_099_140)

    await model.refreshAccountData(at: start)
    #expect(await reads.count == 1)
    #expect(model.usageStatusByAccountID[fixture.account.id] == .available(try usage(used: 10)))
    await model.refreshAccountData(at: start.addingTimeInterval(59))
    #expect(await reads.count == 1)
    await model.refreshAccountData(at: start.addingTimeInterval(60))
    #expect(await reads.count == 2)
    #expect(model.usageStatusByAccountID[fixture.account.id] == .available(try usage(used: 20)))

    await reads.failNextRead()
    await model.refreshAllAuthStatuses()
    #expect(model.accountIssue(for: fixture.account)?.details == "Usage is unavailable.")
    guard case .failed = model.usageStatusByAccountID[fixture.account.id] else {
      Issue.record("The last successful quota must not hide the read failure")
      return
    }
    await model.refreshAllAuthStatuses()
    #expect(model.accountIssue(for: fixture.account) == nil)
    #expect(model.usageStatusByAccountID[fixture.account.id] == .available(try usage(used: 40)))
  }

  @Test
  func updatesLastUsedWithoutRefetchingQuotaAndExposesCorruptRecords() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let reads = UsageSequence()
    let model = fixture.model(usageReader: AccountUsageReader { _, _ in try await reads.read() })
    let start = Date(timeIntervalSince1970: 1_789_099_140)
    await model.refreshAccountData(at: start)
    #expect(model.lastUsedByAccountID[fixture.account.id] == .neverUsed)
    let recordURL = try fixture.store.ensureAuthHome(forAccountID: fixture.account.id)
      .deletingLastPathComponent().appending(path: "last-used.json")
    try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1,
      "accountId": fixture.account.id.uuidString,
      "startedAtUnixSeconds": Int(start.timeIntervalSince1970),
    ]).write(to: recordURL, options: .atomic)
    await model.refreshAccountData(at: start.addingTimeInterval(5))
    #expect(model.lastUsedByAccountID[fixture.account.id] == .used(start))
    #expect(await reads.count == 1)
    try Data("{".utf8).write(to: recordURL, options: .atomic)
    await model.refreshAccountData(at: start.addingTimeInterval(10))
    guard case .failed = model.lastUsedByAccountID[fixture.account.id] else {
      Issue.record("Corrupt Last used metadata must produce an error")
      return
    }
    #expect(await reads.count == 1)
  }

  @Test
  func ignoresAnInflightQuotaResultAfterAccountRemovalAndDoesNotOverlapRefreshes() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let gate = ReadGate()
    let model = fixture.model(usageReader: AccountUsageReader { _, _ in await gate.read() })
    let pending = Task { await model.refreshAllAuthStatuses() }
    await gate.waitUntilRequested()
    await model.refreshAllAuthStatuses()
    #expect(await gate.count == 1)

    let removal = try #require(model.remove(account: fixture.account))
    await removal.value
    #expect(model.registryState.accounts.isEmpty)
    #expect(model.accountError == nil)
    await gate.complete(try usage(used: 90))
    await pending.value
    #expect(model.authStatusByAccountID.isEmpty)
    #expect(model.usageStatusByAccountID.isEmpty)
    #expect(model.lastUsedByAccountID.isEmpty)
    #expect(try fixture.store.loadOrInitialize().accounts.isEmpty)
  }
}

@MainActor
private struct Fixture {
  let root: URL
  let store: AccountRegistryStore
  let account: TurnrailAccount

  init() throws {
    root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    store = AccountRegistryStore(rootURL: root)
    let state = try store.registerAccount(
      identity: ChatGPTAccountIdentity(email: "account@example.com", planType: .pro),
      to: store.loadOrInitialize()
    )
    account = try #require(state.accounts.first)
  }

  func model(usageReader: AccountUsageReader) -> TurnrailViewModel {
    TurnrailViewModel(
      engineURLResult: .success(URL(filePath: "/unused-test-engine")),
      registryStoreResult: .success(store),
      commandExecutor: CommandExecutor { _, _, _ in
        CommandResult(exitCode: 0, standardOutput: "", standardError: "")
      },
      identityReader: AccountIdentityReader { _, _ in
        try ChatGPTAccountIdentity(email: "account@example.com", planType: .pro)
      },
      usageReader: usageReader
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private actor UsageSequence {
  private(set) var count = 0
  private var shouldFail = false

  func failNextRead() { shouldFail = true }

  func read() throws -> AccountRateLimits {
    count += 1
    if shouldFail {
      shouldFail = false
      throw UsageError.unavailable
    }
    return try usage(used: count * 10)
  }
}

private enum UsageError: LocalizedError {
  case unavailable
  var errorDescription: String? { "Usage is unavailable." }
}

private actor ReadGate {
  private(set) var count = 0
  private var response: CheckedContinuation<AccountRateLimits, Never>?
  private var requested: CheckedContinuation<Void, Never>?

  func read() async -> AccountRateLimits {
    count += 1
    requested?.resume()
    requested = nil
    return await withCheckedContinuation { response = $0 }
  }

  func waitUntilRequested() async {
    if count > 0 { return }
    await withCheckedContinuation { requested = $0 }
  }

  func complete(_ value: AccountRateLimits) {
    response?.resume(returning: value)
    response = nil
  }
}

private actor IdentityGate {
  private var count = 0
  private var response: CheckedContinuation<Void, Never>?
  private var requested: CheckedContinuation<Void, Never>?

  func read() async throws -> ChatGPTAccountIdentity {
    count += 1
    if count == 1 {
      requested?.resume()
      requested = nil
      await withCheckedContinuation { response = $0 }
      return try ChatGPTAccountIdentity(email: "account@example.com", planType: .team)
    }
    return try ChatGPTAccountIdentity(email: "account@example.com", planType: .pro)
  }

  func waitUntilRequested() async {
    if count > 0 { return }
    await withCheckedContinuation { requested = $0 }
  }

  func complete() {
    response?.resume()
    response = nil
  }
}

private func usage(used: Int) throws -> AccountRateLimits {
  AccountRateLimits(buckets: [
    AccountRateLimitBucket(
      limitID: "codex", name: nil,
      primary: try AccountRateLimitWindow(
        usedPercent: used, windowDurationMinutes: 300,
        resetsAt: Date(timeIntervalSince1970: 2_000_000_000)
      ),
      secondary: nil
    )
  ])
}
