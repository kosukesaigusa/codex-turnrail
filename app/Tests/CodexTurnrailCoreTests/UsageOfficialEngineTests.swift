import Darwin
import Foundation
import Testing

@testable import CodexTurnrailCore

extension RouterOfficialEngineTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(1)))
  func officialQuotaReadUsesMemoryOnlyCredentialsAndDoesNotHoldTheAccountLock() throws {
    let app = try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"])
    let engine = try OfficialEngineInstallation.verify(app: URL(filePath: app)).paths.launcher
    let root = try RouterTestDirectory()
    let authFile = root.url.appending(path: "auth.json")
    let sentinel = try RouterJSON.data(["OPENAI_API_KEY": "SYNTHETIC_MUST_REMAIN_UNCHANGED"])
    try RouterJSON.writePrivate(sentinel, to: authFile)
    let claims: [String: Any] = [
      "exp": Date().addingTimeInterval(3_600).timeIntervalSince1970,
      "email": "fixture@example.com",
      "https://api.openai.com/auth": [
        "chatgpt_account_id": "fixture-workspace", "chatgpt_plan_type": "pro",
      ],
    ]
    let encoded = try RouterJSON.data(claims).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    let credential = RouterCredential(
      accessToken: "eyJhbGciOiJub25lIn0." + encoded + ".synthetic",
      accountID: "fixture-workspace", expiresAt: Date().addingTimeInterval(3_600))
    let backend = try UsageInspectionBackend(home: root.url, credential: credential)
    defer { backend.stop() }
    let overrides = [
      "cli_auth_credentials_store=\"ephemeral\"", "analytics.enabled=false",
      "features.remote_models=false", "chatgpt_base_url=" + RouterJSON.quote(backend.url),
    ]
    let limits = try AccountUsageInspection.read(
      home: root.url, authenticate: { credential },
      fetch: { credential in
        let rpc = try OfficialEngineRPC(engine: engine, home: root.url, overrides: overrides)
        defer { rpc.close() }
        return try AccountUsageInspection.fetch(credential, request: rpc.request)
      })
    #expect(limits.buckets.first?.primary?.usedPercent == 23)
    #expect(limits.resetCredits?.availableCount == 2)
    #expect(backend.usageReads == 1)
    #expect(try Data(contentsOf: authFile) == sentinel)

    let fresh = try OfficialEngineRPC(engine: engine, home: root.url, overrides: overrides)
    defer { fresh.close() }
    let status = try fresh.request("getAuthStatus", ["includeToken": true, "refreshToken": false])
    let hasNoPersistedToken = status["authToken"] is NSNull
    #expect(hasNoPersistedToken)
    #expect(try Data(contentsOf: authFile) == sentinel)
  }
}

private final class UsageInspectionBackend: @unchecked Sendable {
  private let listener: RouterListener
  private let lock = NSLock()
  private var reads = 0
  var usageReads: Int { lock.withLock { reads } }
  var url: String { "http://127.0.0.1:\(listener.port)/backend-api" }

  init(home: URL, credential: RouterCredential) throws {
    listener = try RouterListener()
    listener.start { [weak self] socket in
      do {
        guard let request = try Self.request(socket) else { return }
        guard request.path == "/backend-api/wham/usage" else {
          try socket.reply(status: 404, body: ["error": "No synthetic data for this endpoint"])
          return
        }
        let usesSyntheticToken =
          request.headers["authorization"] == "Bearer " + credential.accessToken
        let usesSyntheticWorkspace = request.headers["chatgpt-account-id"] == credential.accountID
        #expect(usesSyntheticToken)
        #expect(usesSyntheticWorkspace)
        let descriptor = open(home.appending(path: ".turnrail-auth.lock").path, O_RDWR)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        // The service has received the quota request but has not responded yet.
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        flock(descriptor, LOCK_UN)
        self?.lock.withLock { self?.reads += 1 }
        try socket.reply(
          status: 200,
          body: [
            "plan_type": "pro",
            "rate_limit": [
              "allowed": true, "limit_reached": false,
              "primary_window": [
                "used_percent": 23, "limit_window_seconds": 3_600,
                "reset_after_seconds": 120, "reset_at": 2_000_000_000,
              ],
            ],
            "rate_limit_reset_credits": ["available_count": 2],
          ])
      } catch { Issue.record(error) }
    }
  }

  func stop() { listener.stop() }

  static func request(_ socket: RouterSocket) throws -> RouterHTTPRequest? {
    // The Engine may close a background connection without sending an HTTP request.
    // Preserve parser failures once any request byte has arrived.
    var firstByte: UInt8 = 0
    while true {
      let count = recv(socket.descriptor, &firstByte, 1, MSG_PEEK)
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { throw RouterFailure("Could not read the usage fixture connection.") }
      guard count > 0 else { return nil }
      return try socket.request()
    }
  }
}

struct UsageInspectionBackendTests {
  @Test
  func unusedConnectionsCanCloseBeforeSendingARequest() throws {
    let pair = try UsageInspectionSocketPair()
    pair.client.close()
    #expect(try UsageInspectionBackend.request(pair.server) == nil)
  }

  @Test(arguments: ["GET /backend-api/wham/usage HTTP/1.1\r\n", "INVALID\r\n\r\n"])
  func partialAndMalformedRequestsRemainFailures(_ request: String) throws {
    let pair = try UsageInspectionSocketPair()
    try pair.client.write(Data(request.utf8))
    pair.client.close()
    #expect(throws: RouterFailure.self) {
      _ = try UsageInspectionBackend.request(pair.server)
    }
  }

  @Test
  func aReceiveTimeoutIsNotAnUnusedClosedConnection() throws {
    let pair = try UsageInspectionSocketPair()
    var timeout = timeval(tv_sec: 0, tv_usec: 50_000)
    try #require(
      setsockopt(
        pair.server.descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
        socklen_t(MemoryLayout.size(ofValue: timeout))) == 0)
    #expect(throws: RouterFailure.self) {
      _ = try UsageInspectionBackend.request(pair.server)
    }
  }
}

private final class UsageInspectionSocketPair {
  let server: RouterSocket
  let client: RouterSocket

  init() throws {
    var pair: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
      throw RouterFailure("Could not create a usage fixture socket pair.")
    }
    server = RouterSocket(pair[0])
    client = RouterSocket(pair[1])
  }

  deinit {
    server.close()
    client.close()
  }
}
