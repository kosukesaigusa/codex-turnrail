import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterQuotaReaderTests {
  @Test
  func successfulQuotaAndOptionalFailuresRemainDistinct() throws {
    let cases: [(Int, [String: Any], RouterQuotaAvailability)] = [
      (200, ["rate_limit": ["allowed": true, "limit_reached": false]], .available),
      (200, ["rate_limit": ["allowed": false, "limit_reached": true]], .exhausted),
      (200, [:], .unavailable(.invalidResponse)),
      (200, ["rate_limit": ["allowed": "true"]], .unavailable(.invalidResponse)),
      (429, ["message": "PRIVATE_SERVER_TEXT"], .unavailable(.httpStatus(429))),
      (503, ["message": "PRIVATE_SERVER_TEXT"], .unavailable(.httpStatus(503))),
    ]
    for (status, body, expected) in cases {
      let encoded = try RouterJSON.data(body)
      let server = try QuotaHTTPServer { socket, _ in
        try socket.reply(status: status, data: encoded)
      }
      defer { server.stop() }
      let result = try RouterQuotaReader.read(
        url: server.url, credential: Self.credential, deadline: .now() + 3)
      #expect(result == expected)
      #expect(server.requests == 1)
      if case .unavailable(let reason) = result {
        #expect(!reason.diagnostic.contains("PRIVATE_SERVER_TEXT"))
      }
    }
  }

  @Test
  func credentialAndPermissionRejectionsAreNotUnknownQuota() throws {
    for status in [401, 403] {
      let server = try QuotaHTTPServer { socket, _ in
        try socket.reply(status: status, body: ["error": "PRIVATE_SERVER_TEXT"])
      }
      defer { server.stop() }
      do {
        _ = try RouterQuotaReader.read(
          url: server.url, credential: Self.credential, deadline: .now() + 3)
        Issue.record("A credential or permission rejection was ignored.")
      } catch {
        #expect(!error.localizedDescription.contains("PRIVATE_SERVER_TEXT"))
        if status == 401 {
          #expect(error is RouterAccountUnavailable)
        } else {
          #expect(error is RouterFailure)
          #expect(error.localizedDescription.contains("HTTP 403"))
        }
      }
    }
  }

  @Test
  func failedTransportAndMalformedJSONDoNotBecomeExhaustion() throws {
    let unavailable = try RouterQuotaReader.read(
      url: #require(URL(string: "invalid-fixture://host/usage?token=SECRET")),
      credential: Self.credential, deadline: .now() + 3)
    #expect(unavailable == .unavailable(.transport))
    let server = try QuotaHTTPServer { socket, _ in
      try socket.reply(status: 200, data: Data("PRIVATE_NOT_JSON".utf8))
    }
    defer { server.stop() }
    #expect(
      try RouterQuotaReader.read(url: server.url, credential: Self.credential, deadline: .now() + 3)
        == .unavailable(.invalidResponse))
  }

  @Test
  func redirectsNeverForwardCredentialsOrCountAsAvailableQuota() throws {
    let destination = try QuotaHTTPServer { socket, _ in
      try socket.reply(status: 200, body: [:])
    }
    defer { destination.stop() }
    let location = destination.url.absoluteString
    let server = try QuotaHTTPServer { socket, _ in
      try socket.write(
        Data(
          ("HTTP/1.1 302 Redirect\r\nLocation: \(location)\r\nContent-Length: 0\r\n"
            + "Connection: close\r\n\r\n").utf8))
    }
    defer { server.stop() }
    #expect(
      try RouterQuotaReader.read(url: server.url, credential: Self.credential, deadline: .now() + 3)
        == .unavailable(.httpStatus(302)))
    #expect(server.requests == 1)
    #expect(destination.requests == 0)
  }

  @Test(.timeLimit(.minutes(1)))
  func aStalledQuotaReadIsCancelledAndTheNextTurnCanCheckAgain() throws {
    let closed = DispatchSemaphore(value: 0)
    let server = try QuotaHTTPServer { socket, index in
      if index == 1 {
        _ = try? socket.read(1)
        closed.signal()
      } else {
        try socket.reply(
          status: 200, body: ["rate_limit": ["allowed": true, "limit_reached": false]])
      }
    }
    defer { server.stop() }
    let fixture = try QuotaSelectionFixture(server: server, quotaWait: 0.3)
    let start = ProcessInfo.processInfo.systemUptime
    let selected = try fixture.router.select(cwd: fixture.root.url.path)
    #expect(selected.account.id == fixture.accounts[0].id)
    #expect(ProcessInfo.processInfo.systemUptime - start < 2)
    #expect(closed.wait(timeout: .now() + 3) == .success)
    #expect(fixture.observations.warnings == [.timedOut])
    #expect(try fixture.router.select(cwd: fixture.root.url.path) === selected)
    #expect(fixture.observations.results == [.unavailable(.timedOut), .available])
    #expect(server.requests == 2)
  }

  @Test(.timeLimit(.minutes(1)))
  func candidatesShareTheQuotaBudgetInsteadOfStartingAnotherFullWait() throws {
    let closed = DispatchSemaphore(value: 0)
    let server = try QuotaHTTPServer { socket, index in
      if index == 1 {
        Thread.sleep(forTimeInterval: 0.25)
        try socket.reply(
          status: 200, body: ["rate_limit": ["allowed": false, "limit_reached": true]])
      } else {
        _ = try? socket.read(1)
        closed.signal()
      }
    }
    defer { server.stop() }
    let fixture = try QuotaSelectionFixture(server: server, quotaWait: 1)
    _ = try fixture.router.commonCatalog()
    let start = ProcessInfo.processInfo.systemUptime
    let selected = try fixture.router.select(cwd: fixture.root.url.path)
    #expect(selected.account.id == fixture.accounts[1].id)
    #expect(ProcessInfo.processInfo.systemUptime - start < 2)
    #expect(closed.wait(timeout: .now() + 3) == .success)
    let remaining = fixture.observations.remaining
    try #require(remaining.count == 2)
    #expect(remaining[0] > 0.9)
    #expect(remaining[1] < 0.8)
    #expect(fixture.observations.results == [.exhausted, .unavailable(.timedOut)])
    #expect(fixture.observations.warnings == [.timedOut])
    #expect(server.requests == 2)
  }

  @Test
  func anExpiredDeadlineDoesNotStartANetworkRequest() throws {
    let server = try QuotaHTTPServer { _, _ in Issue.record("An expired request was sent.") }
    defer { server.stop() }
    #expect(
      try RouterQuotaReader.read(url: server.url, credential: Self.credential, deadline: .now())
        == .unavailable(.timedOut))
    #expect(server.requests == 0)
  }

  private static let credential = RouterCredential(
    accessToken: "SYNTHETIC_QUOTA", accountID: "fixture", expiresAt: .distantFuture)
}

private final class QuotaHTTPServer: @unchecked Sendable {
  private let listener: RouterListener
  private let lock = NSLock()
  private var count = 0
  var requests: Int { lock.withLock { count } }
  var url: URL { URL(string: "http://127.0.0.1:\(listener.port)/backend-api/wham/usage")! }

  init(handler: @escaping @Sendable (RouterSocket, Int) throws -> Void) throws {
    listener = try RouterListener()
    listener.start { [weak self] socket in
      do {
        let request = try socket.request()
        #expect(request.method == "GET")
        #expect(request.headers["authorization"] == "Bearer SYNTHETIC_QUOTA")
        guard let self else { return }
        let index = lock.withLock {
          count += 1
          return count
        }
        try handler(socket, index)
      } catch { Issue.record(error) }
    }
  }

  func stop() { listener.stop() }
}

private final class QuotaObservations: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedWarnings: [RouterQuotaUnavailable] = []
  private var recordedResults: [RouterQuotaAvailability] = []
  private var recordedRemaining: [TimeInterval] = []
  var warnings: [RouterQuotaUnavailable] { lock.withLock { recordedWarnings } }
  var results: [RouterQuotaAvailability] { lock.withLock { recordedResults } }
  var remaining: [TimeInterval] { lock.withLock { recordedRemaining } }

  func start(deadline: DispatchTime) {
    let current = DispatchTime.now().uptimeNanoseconds
    let nanoseconds =
      deadline.uptimeNanoseconds > current ? deadline.uptimeNanoseconds - current : 0
    lock.withLock {
      recordedRemaining.append(Double(nanoseconds) / 1_000_000_000)
    }
  }
  func result(_ result: RouterQuotaAvailability) {
    lock.withLock { recordedResults.append(result) }
  }
  func warn(_ reason: RouterQuotaUnavailable) { lock.withLock { recordedWarnings.append(reason) } }
}

private struct QuotaSelectionFixture {
  let root: RouterTestDirectory
  let accounts: [TurnrailAccount]
  let router: RouterAccounts
  let observations = QuotaObservations()

  init(server: QuotaHTTPServer, quotaWait: TimeInterval) throws {
    root = try RouterTestDirectory()
    accounts = try ["first@example.com", "second@example.com"].map {
      try TurnrailAccount(id: UUID(), email: $0, planType: .pro)
    }
    let registry = AccountRegistryState(
      schemaVersion: AccountRegistryState.currentSchemaVersion, revision: 1, accounts: accounts,
      routing: AccountRoutingConfiguration(
        defaultAccountIDs: accounts.map(\.id), directoryRules: []))
    try RouterJSON.writePrivate(
      JSONEncoder().encode(registry), to: root.url.appending(path: "state.json"))
    let observations = observations
    router = try RouterAccounts(
      root: root.url, engineVersion: "codex-cli 0.1.0",
      authenticate: { account, _, _ in
        RouterCredential(
          accessToken: "SYNTHETIC_QUOTA", accountID: account.id.uuidString,
          expiresAt: .distantFuture)
      }, get: { _, _ in ["models": [["slug": "fixture"]]] },
      readQuota: { credential, deadline in
        observations.start(deadline: deadline)
        let result = try RouterQuotaReader.read(
          url: server.url, credential: credential, deadline: deadline)
        observations.result(result)
        return result
      }, quotaWait: quotaWait, reportQuotaUnavailable: observations.warn, now: Date.init)
  }
}
