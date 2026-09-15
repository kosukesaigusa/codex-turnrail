import Foundation
import Testing

@testable import CodexTurnrailCore

struct AccountResetCreditsTests {
  @Test
  func readsCreditsThroughTheUsageResponseAndSortsEarliestExpiryFirst() throws {
    let credits = [
      credit("later", expires: 2_000_000_200),
      credit("no-expiry", expires: NSNull()),
      credit("sooner", expires: 2_000_000_100),
    ]
    let summary = try #require(read(["availableCount": 3, "credits": credits]).resetCredits)
    #expect(summary.availableCount == 3)
    #expect(summary.availableCredits?.map(\.id) == ["sooner", "later", "no-expiry"])
    #expect(
      summary.availableCredits?.first?.expiresAt == Date(timeIntervalSince1970: 2_000_000_100))
    #expect(summary.availableCredits?.last?.expiresAt == nil)
    #expect(summary.availableCredits?.first?.displayTitle == "Full reset")
  }

  @Test
  func preservesUnknownAvailabilityAndUnavailableDetailsSeparatelyFromZero() throws {
    #expect(try read(NSNull()).resetCredits == nil)
    let countOnly = try #require(read(["availableCount": 2, "credits": NSNull()]).resetCredits)
    #expect(countOnly.availableCount == 2)
    #expect(countOnly.availableCredits == nil)
    let empty = try #require(read(["availableCount": 0, "credits": []]).resetCredits)
    #expect(empty.availableCredits == [])
  }

  @Test
  func preservesACappedListWithoutReplacingTheServerCount() throws {
    let summary = try #require(
      read(["availableCount": 5, "credits": [credit("one", expires: 2_000_000_100)]]).resetCredits)
    #expect(summary.availableCount == 5)
    #expect(summary.availableCredits?.count == 1)
  }

  @Test
  func excludesRedeemedAndInProgressCreditsFromTheAvailableList() throws {
    var redeemed = credit("redeemed", expires: 2_000_000_100)
    redeemed["status"] = "redeemed"
    var redeeming = credit("redeeming", expires: 2_000_000_100)
    redeeming["status"] = "redeeming"
    let summary = try #require(
      read([
        "availableCount": 1,
        "credits": [redeemed, redeeming, credit("available", expires: 2_000_000_100)],
      ]).resetCredits)
    #expect(summary.availableCredits?.map(\.id) == ["available"])
  }

  @Test
  func keepsBackendTitlesAndDoesNotMislabelUnknownResetTypes() throws {
    var unknown = credit("unknown", expires: NSNull())
    unknown["resetType"] = "unknown"
    var named = credit("named", expires: NSNull())
    named["title"] = "Weekly reset"
    let summary = try #require(
      read(["availableCount": 2, "credits": [unknown, named]]).resetCredits)
    #expect(summary.availableCredits?.map(\.displayTitle) == ["Weekly reset", "Unknown reset"])
  }

  @Test(arguments: ["-1", "true", "1.5", #""2""#])
  func rejectsInvalidCounts(_ count: String) {
    #expect(throws: (any Error).self) {
      try AccountUsageProtocol.parseRateLimitsResponse(
        #"{"id":3,"result":{"rateLimits":{"primary":null},"rateLimitsByLimitId":null,"rateLimitResetCredits":{"availableCount":\#(count),"credits":null}}}"#
      )
    }
  }

  @Test
  func rejectsDuplicateIDsAndDetailsExceedingTheAvailableCount() {
    let item = credit("same", expires: 2_000_000_100)
    #expect(throws: (any Error).self) { try read(["availableCount": 2, "credits": [item, item]]) }
    #expect(throws: (any Error).self) { try read(["availableCount": 0, "credits": [item]]) }
  }

  @Test(arguments: ["id", "resetType", "status", "grantedAt", "expiresAt"])
  func rejectsMissingRequiredDetailFields(_ key: String) {
    var item = credit("one", expires: 2_000_000_100)
    item.removeValue(forKey: key)
    #expect(throws: (any Error).self) { try read(["availableCount": 1, "credits": [item]]) }
  }

  @Test
  func rejectsMalformedDetailsInsteadOfReportingZeroResets() {
    #expect(throws: (any Error).self) { try read(["availableCount": 2, "credits": "invalid"]) }
    var item = credit("one", expires: -1)
    #expect(throws: (any Error).self) { try read(["availableCount": 1, "credits": [item]]) }
    item["expiresAt"] = "tomorrow"
    #expect(throws: (any Error).self) { try read(["availableCount": 1, "credits": [item]]) }
    item["expiresAt"] = 253_402_300_800 as Int64
    #expect(throws: (any Error).self) { try read(["availableCount": 1, "credits": [item]]) }
  }

  private func credit(_ id: String, expires: Any) -> [String: Any] {
    [
      "id": id, "resetType": "codexRateLimits", "status": "available",
      "grantedAt": 1_999_000_000, "expiresAt": expires, "title": NSNull(),
    ]
  }

  private func read(_ summary: Any) throws -> AccountRateLimits {
    let object: [String: Any] = [
      "id": 3,
      "result": [
        "rateLimits": ["limitId": "codex", "primary": NSNull()],
        "rateLimitsByLimitId": NSNull(), "rateLimitResetCredits": summary,
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    return try AccountUsageProtocol.parseRateLimitsResponse(String(decoding: data, as: UTF8.self))
  }
}
