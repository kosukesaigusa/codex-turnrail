import Foundation
import Testing

@testable import CodexTurnrailCore

struct AccountUsageReaderTests {
  @Test
  func buildsTheExactRateLimitsRequest() {
    #expect(
      AccountUsageProtocol.rateLimitsReadRequest
        == #"{"id":3,"method":"account/rateLimits/read"}"#)
  }

  @Test
  func parsesAndSortsEveryMeteredBucket() throws {
    let rateLimits = try AccountUsageProtocol.parseRateLimitsResponse(
      #"{"id":3,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":27,"windowDurationMins":10080,"resetsAt":1788137885},"secondary":null},"rateLimitsByLimitId":{"codex_bengalfox":{"limitId":"codex_bengalfox","limitName":"GPT-5.3-Codex-Spark","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1787591056},"secondary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":1788177856}},"codex":{"limitId":"codex","limitName":null,"primary":{"usedPercent":27,"windowDurationMins":10080,"resetsAt":1788137885},"secondary":null}}}}"#
    )

    #expect(
      rateLimits
        == AccountRateLimits(
          buckets: [
            AccountRateLimitBucket(
              limitID: "codex",
              name: nil,
              primary: try AccountRateLimitWindow(
                usedPercent: 27,
                windowDurationMinutes: 10_080,
                resetsAt: Date(timeIntervalSince1970: 1_788_137_885)
              ),
              secondary: nil
            ),
            AccountRateLimitBucket(
              limitID: "codex_bengalfox",
              name: "GPT-5.3-Codex-Spark",
              primary: try AccountRateLimitWindow(
                usedPercent: 0,
                windowDurationMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 1_787_591_056)
              ),
              secondary: try AccountRateLimitWindow(
                usedPercent: 10,
                windowDurationMinutes: 10_080,
                resetsAt: Date(timeIntervalSince1970: 1_788_177_856)
              )
            ),
          ],
          resetCredits: nil
        ))
    #expect(rateLimits.buckets[0].primary?.remainingPercent == 73)
  }

  @Test
  func usesTheContractualHistoricalSnapshotWhenMultiBucketDataIsNull() throws {
    let rateLimits = try AccountUsageProtocol.parseRateLimitsResponse(
      #"{"id":3,"result":{"rateLimits":{"limitId":"codex","limitName":null,"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1730947200},"secondary":null},"rateLimitsByLimitId":null}}"#
    )

    #expect(rateLimits.buckets.count == 1)
    #expect(rateLimits.buckets[0].limitID == "codex")
    #expect(rateLimits.buckets[0].primary?.remainingPercent == 75)
  }

  @Test
  func rejectsUsageOutsideTheOfficialPercentageRange() {
    #expect(throws: AccountReaderError.invalidUsage("usedPercent must be between 0 and 100")) {
      try AccountUsageProtocol.parseRateLimitsResponse(
        #"{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":101,"windowDurationMins":300,"resetsAt":1730947200},"secondary":null},"rateLimitsByLimitId":null}}"#
      )
    }
  }

  @Test
  func rejectsAMalformedMultiBucketPayloadInsteadOfHidingIt() {
    #expect(throws: AccountReaderError.invalidResponse) {
      try AccountUsageProtocol.parseRateLimitsResponse(
        #"{"id":3,"result":{"rateLimits":{"primary":null,"secondary":null},"rateLimitsByLimitId":[]}}"#
      )
    }
  }

  @Test
  func marksAnExpiredTokenForExplicitReauthentication() throws {
    let embeddedBody = #"{"error":{"code":"token_expired"},"status":401}"#
    let responseData = try JSONSerialization.data(
      withJSONObject: [
        "id": 3,
        "error": [
          "code": -32603,
          "message": "failed to fetch rate limits: 401 Unauthorized; body=\(embeddedBody)",
        ],
      ]
    )
    let response = String(decoding: responseData, as: UTF8.self)

    do {
      _ = try AccountUsageProtocol.parseRateLimitsResponse(response)
      Issue.record("Expected the rate-limit read to fail.")
    } catch AccountReaderError.serverError(let failure) {
      #expect(failure.recoveryAction == .reauthenticate)
      #expect(failure.diagnosticJSON.contains("token_expired"))
      #expect(failure.diagnosticJSON.contains(#""id" : 3"#))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func doesNotSuggestReauthenticationForAnUnrelatedServerError() {
    do {
      _ = try AccountUsageProtocol.parseRateLimitsResponse(
        #"{"id":3,"error":{"code":-32603,"message":"network unavailable"}}"#
      )
      Issue.record("Expected the rate-limit read to fail.")
    } catch AccountReaderError.serverError(let failure) {
      #expect(failure.recoveryAction == nil)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test
  func readsLiveRateLimitsWhenExplicitPathsAreProvided() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let enginePath = environment["CODEX_TURNRAIL_LIVE_ENGINE_PATH"],
      let authHomePath = environment["CODEX_TURNRAIL_LIVE_AUTH_HOME"]
    else {
      return
    }

    let rateLimits = try await AccountUsageReader.live.read(
      engineURL: URL(filePath: enginePath),
      authHomeURL: URL(filePath: authHomePath)
    )

    #expect(!rateLimits.buckets.isEmpty)
    #expect(rateLimits.buckets.allSatisfy { $0.primary != nil || $0.secondary != nil })
  }
}
