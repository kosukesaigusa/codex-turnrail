import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterSearchTests {
  @Test
  func searchUsesTheModelTurnAccountAndDoesNotForwardDesktopCredentials() throws {
    let root = try RouterTestDirectory()
    let accounts = SearchAccounts(root: root.url)
    let capture = SearchCapture()
    let runtime = try makeRuntime(accounts, capture)
    defer { runtime.stop() }
    try runtime.ledger.bind("task/turn", account: accounts.account.account.id)
    let payload = try RouterJSON.data([
      "id": "independent-search-session", "model": "fixture",
      "commands": ["search_query": [["q": "synthetic query"]]],
    ])
    var headers = try metadata("task", "turn")
    headers["authorization"] = "Bearer WRONG_DESKTOP_ACCOUNT"
    headers["chatgpt-account-id"] = "WRONG_DESKTOP_WORKSPACE"
    headers["cookie"] = "DO_NOT_FORWARD"
    headers["x-codex-turn-state"] = "DO_NOT_FORWARD"
    headers["originator"] = "Codex Desktop"
    let output = try runtime.webSearch(payload, headers: headers)
    #expect(try RouterJSON.text(RouterJSON.object(output), "output") == "synthetic result")
    let request = try #require(capture.requests.first)
    #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/codex/alpha/search")
    #expect(request.httpMethod == "POST")
    #expect(request.httpBody == payload)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer BOUND_ACCOUNT")
    #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "bound-workspace")
    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(request.value(forHTTPHeaderField: "x-codex-turn-state") == nil)
    #expect(
      request.value(forHTTPHeaderField: "x-codex-turn-metadata") == headers["x-codex-turn-metadata"]
    )
    #expect(request.value(forHTTPHeaderField: "originator") == "Codex Desktop")
    #expect(capture.requests.count == 1)
  }

  @Test
  func searchRequiresItsExistingTurnEvenWhenBodyOrParentIdentifyABoundAccount() throws {
    let root = try RouterTestDirectory()
    let accounts = SearchAccounts(root: root.url)
    let capture = SearchCapture()
    let runtime = try makeRuntime(accounts, capture)
    defer { runtime.stop() }
    try runtime.ledger.bind("task/turn", account: accounts.account.account.id)
    let payload = try RouterJSON.data(["id": "task", "model": "fixture"])
    for headers in [[:], try metadata("task", "another-turn"), try metadata("child", "turn")] {
      #expect(throws: RouterFailure.self) { try runtime.webSearch(payload, headers: headers) }
    }
    // A child search has no parent_turn_id in the official tool metadata. Its
    // preceding model request already bound the account; no new selection is made.
    try runtime.ledger.bind("child/turn", account: accounts.account.account.id)
    _ = try runtime.webSearch(payload, headers: metadata("child", "turn"))
    #expect(capture.requests.count == 1)
  }

  @Test
  func uncertainSearchIsNotReplayedAndANewTurnCanContinue() throws {
    let root = try RouterTestDirectory()
    let accounts = SearchAccounts(root: root.url)
    let capture = SearchCapture()
    let runtime = try makeRuntime(accounts, capture)
    defer { runtime.stop() }
    let payload = try RouterJSON.data(["id": "session", "model": "fixture"])
    try runtime.ledger.bind("task/failed", account: accounts.account.account.id)
    capture.setFailure(true)
    for _ in 0..<2 {
      #expect(throws: RouterFailure.self) {
        try runtime.webSearch(payload, headers: metadata("task", "failed"))
      }
    }
    #expect(capture.requests.count == 1)
    capture.setFailure(false)
    try runtime.ledger.bind("task/next", account: accounts.account.account.id)
    _ = try runtime.webSearch(payload, headers: metadata("task", "next"))
    #expect(throws: RouterFailure.self) {
      try runtime.webSearch(payload, headers: metadata("task", "next"))
    }
    #expect(capture.requests.count == 2)
  }

  @Test
  func completedSearchDoesNotLeaveTheLedgerUncertainAfterRestart() throws {
    let root = try RouterTestDirectory()
    let account = UUID()
    do {
      let ledger = try RouterLedger(root: root.url)
      try ledger.bind("task/turn", account: account)
      try ledger.begin("search-fingerprint", turn: "task/turn")
      try ledger.finish("search-fingerprint", turn: "task/turn")
      #expect(throws: RouterFailure.self) { try ledger.finish("unknown", turn: "task/turn") }
    }
    let restored = try RouterLedger(root: root.url)
    #expect(try restored.bound("task/turn") == account)
    #expect(throws: RouterFailure.self) {
      try restored.begin("search-fingerprint", turn: "task/turn")
    }
  }

  @Test
  func accountHttpClientRejectsRedirectsAndOversizedBodies() throws {
    let listener = try RouterListener()
    listener.start { socket in
      do {
        let request = try socket.request()
        switch request.path {
        case "/redirect":
          try socket.write(
            Data(
              "HTTP/1.1 302 Found\r\nLocation: /destination\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                .utf8))
        case "/destination":
          try socket.reply(status: 200, body: ["unexpected": "redirect followed"])
        case "/large":
          try socket.reply(status: 200, data: Data(repeating: 65, count: 2048))
        default: try socket.reply(status: 400, body: [:])
        }
      } catch {}
    }
    defer { listener.stop() }
    let url = URL(string: "http://127.0.0.1:\(listener.port)")!
    let (body, status) = try RouterHTTP.exchange(
      URLRequest(url: url.appending(path: "redirect")), maximumBytes: 1024)
    #expect(status == 302)
    #expect(body.isEmpty)
    #expect(throws: RouterFailure.self) {
      try RouterHTTP.exchange(URLRequest(url: url.appending(path: "large")), maximumBytes: 1024)
    }
  }

  private func metadata(_ thread: String, _ turn: String) throws -> [String: String] {
    ["x-codex-turn-metadata": try RouterJSON.string(["thread_id": thread, "turn_id": turn])]
  }

  private func makeRuntime(_ accounts: SearchAccounts, _ capture: SearchCapture) throws
    -> RouterRuntime
  {
    try RouterRuntime(
      root: accounts.root, accounts: accounts,
      connect: { _, _ in fatalError("Search tests cannot contact the model service.") },
      search: { try capture.send($0) })
  }
}

private final class SearchAccounts: RouterAccountProviding, @unchecked Sendable {
  let root: URL
  let account: RouterAccountSnapshot
  init(root: URL) {
    self.root = root
    account = RouterAccountSnapshot(
      account: try! TurnrailAccount(id: UUID(), email: "bound@example.com", planType: .pro),
      credential: RouterCredential(
        accessToken: "BOUND_ACCOUNT", accountID: "bound-workspace", expiresAt: .distantFuture),
      models: [["slug": "fixture"]], usable: true, inspectedAt: Date())
  }
  func select(cwd: String) throws -> RouterAccountSnapshot {
    throw RouterFailure("A web search must not select an account.")
  }
  func bound(_ id: UUID) throws -> RouterAccountSnapshot {
    guard id == account.account.id else { throw RouterFailure("Unknown fixture account.") }
    return account
  }
  func commonCatalog() throws -> [String: Any] { ["models": account.models] }
}

private final class SearchCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var received: [URLRequest] = []
  private var failure = false
  var requests: [URLRequest] { lock.withLock { received } }
  func setFailure(_ enabled: Bool) { lock.withLock { failure = enabled } }
  func send(_ request: URLRequest) throws -> Data {
    try lock.withLock {
      received.append(request)
      if failure { throw RouterFailure("Synthetic disconnection after submission.") }
      return try RouterJSON.data(["output": "synthetic result", "results": []])
    }
  }
}
