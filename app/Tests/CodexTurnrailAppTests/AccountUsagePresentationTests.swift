import CodexTurnrailCore
import Foundation
import Testing

@testable import CodexTurnrailApp

struct AccountUsagePresentationTests {
  @Test
  func usesOneExplicitTimeZoneAnd24HourClockForUsageDates() throws {
    let date = Date(timeIntervalSince1970: 1_789_502_880)
    let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
    #expect(UsageTimestampFormat.time.string(from: date, timeZone: .gmt) == "20:08")
    #expect(UsageTimestampFormat.dateTime.string(from: date, timeZone: tokyo) == "Sep 16, 05:08")
  }

  @Test
  func showsBothGeneralLimitsWithoutIncludingModelSpecificQuota() throws {
    let fiveHours = try window(minutes: 300)
    let weekly = try window(minutes: 10_080)
    let limits = AccountRateLimits(
      buckets: [
        AccountRateLimitBucket(limitID: "codex", name: nil, primary: fiveHours, secondary: weekly),
        AccountRateLimitBucket(limitID: "spark", name: "Spark", primary: fiveHours, secondary: nil),
      ], resetCredits: nil)
    let rows = AccountUsageWindow.windows(in: limits)
    #expect(rows.map(\.title) == ["5-hour limit", "Weekly limit"])
    #expect(rows.map(\.window) == [fiveHours, weekly])
    #expect(Set(rows.map(\.id)).count == 2)
  }

  @Test
  func labelsWeeklyPrimaryAndUnknownDurationWithoutInventingAResetTime() throws {
    let limits = AccountRateLimits(
      buckets: [
        AccountRateLimitBucket(
          limitID: nil, name: nil,
          primary: try window(minutes: 10_080), secondary: try window(minutes: nil))
      ], resetCredits: nil)
    let rows = AccountUsageWindow.windows(in: limits)
    #expect(rows.map(\.title) == ["Weekly limit", "Secondary limit"])
    #expect(rows.allSatisfy { $0.window.resetsAt == nil })
  }

  private func window(minutes: Int?) throws -> AccountRateLimitWindow {
    try AccountRateLimitWindow(usedPercent: 66, windowDurationMinutes: minutes, resetsAt: nil)
  }
}
