import Foundation

/// Retains only a bounded Retry-After deadline, never the original response headers.
struct RouterServiceRetryDelay: Codable, Sendable {
  enum State: String, Codable, Sendable { case missing, null, valid, invalid, excessive }
  static let maximumSeconds: TimeInterval = 60
  let state: State
  let deadline: Date?

  init(headers: Any?, now: Date) {
    guard let headers else {
      state = .missing
      deadline = nil
      return
    }
    if headers is NSNull {
      state = .null
      deadline = nil
      return
    }
    guard let headers = headers as? [String: Any] else {
      state = .invalid
      deadline = nil
      return
    }
    let fields = headers.filter { $0.key.lowercased() == "retry-after" }
    guard !fields.isEmpty else {
      state = .missing
      deadline = nil
      return
    }
    guard fields.count == 1, let value = fields.first?.value as? String, !value.isEmpty else {
      state = .invalid
      deadline = nil
      return
    }
    let seconds: TimeInterval
    if value.utf8.allSatisfy({ (48...57).contains($0) }) {
      guard let parsed = TimeInterval(value), parsed.isFinite, parsed <= Self.maximumSeconds else {
        state = .excessive
        deadline = nil
        return
      }
      seconds = parsed
    } else {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
      formatter.isLenient = false
      guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
        state = .invalid
        deadline = nil
        return
      }
      seconds = max(0, date.timeIntervalSince(now))
    }
    guard seconds <= Self.maximumSeconds else {
      state = .excessive
      deadline = nil
      return
    }
    state = .valid
    deadline = now.addingTimeInterval(seconds)
  }

  var permitsRecovery: Bool { state == .missing || state == .null || state == .valid }
}
