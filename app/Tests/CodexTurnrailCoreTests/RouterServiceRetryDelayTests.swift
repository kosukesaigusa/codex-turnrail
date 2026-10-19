import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterServiceRetryDelayTests {
  private let now = Date(timeIntervalSince1970: 1_792_353_600)

  @Test
  func secondsAndHTTPDatesPreserveTheRequestedCooldown() throws {
    for seconds in [0, 1, 60] {
      let delay = RouterServiceRetryDelay(headers: ["Retry-After": String(seconds)], now: now)
      #expect(delay.state == .valid)
      #expect(delay.deadline == now.addingTimeInterval(TimeInterval(seconds)))
      #expect(delay.permitsRecovery)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    for seconds: TimeInterval in [-10, 30] {
      let date = formatter.string(from: now.addingTimeInterval(seconds))
      let delay = RouterServiceRetryDelay(headers: ["retry-after": date], now: now)
      #expect(delay.state == .valid)
      #expect(delay.deadline == now.addingTimeInterval(max(0, seconds)))
    }
  }

  @Test
  func invalidAndExcessiveDelaysNeverAuthorizeAnEarlyRetry() throws {
    for value in ["61", "9999999999999999999999999999999999999"] {
      let delay = RouterServiceRetryDelay(headers: ["retry-after": value], now: now)
      #expect(delay.state == .excessive)
      #expect(delay.deadline == nil)
      #expect(!delay.permitsRecovery)
    }
    for headers: Any in [
      "PRIVATE_HEADER", ["retry-after": -1], ["retry-after": "-1"], ["retry-after": "0.5"],
      ["retry-after": "NaN"], ["retry-after": "PRIVATE_VALUE"], ["retry-after": ""],
      ["retry-after": "1", "Retry-After": "2"],
    ] {
      let delay = RouterServiceRetryDelay(headers: headers, now: now)
      #expect(delay.state == .invalid)
      #expect(!delay.permitsRecovery)
    }
    for value in ["PRIVATE_VALUE", "61"] {
      let failure = try RouterServiceFailure(event: [
        "type": "error", "status": 503, "error": ["code": "server_error"],
        "headers": ["retry-after": value],
      ])
      #expect(!failure.permitsEngineRecovery)
      #expect(!failure.localizedDescription.contains("PRIVATE_"))
    }
    #expect(RouterServiceRetryDelay(headers: nil, now: now).state == .missing)
    #expect(RouterServiceRetryDelay(headers: NSNull(), now: now).state == .null)
    #expect(RouterServiceRetryDelay(headers: NSNull(), now: now).permitsRecovery)
    let nullableHeaders = try RouterServiceFailure(event: [
      "type": "error", "error": ["code": "server_is_overloaded"], "headers": NSNull(),
    ])
    #expect(nullableHeaders.permitsEngineRecovery)
    #expect(
      RouterServiceRetryDelay(headers: ["authorization": "PRIVATE_TOKEN"], now: now).state
        == .missing)
  }

  @Test(.timeLimit(.minutes(1)))
  func recoveryWaitHonorsTheDeadlineAndStopsOnDesktopCancellation() throws {
    let messages = RouterMessages()
    let start = Date()
    #expect(messages.waitForRecovery(until: start.addingTimeInterval(0.05)))
    #expect(Date().timeIntervalSince(start) >= 0.04)
    let waiting = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      waiting.signal()
      #expect(!messages.waitForRecovery(until: Date().addingTimeInterval(60)))
      finished.signal()
    }
    try #require(waiting.wait(timeout: .now() + 2) == .success)
    messages.stop()
    #expect(finished.wait(timeout: .now() + 2) == .success)
  }
}
