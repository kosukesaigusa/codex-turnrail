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
        let request = try socket.request()
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
}
