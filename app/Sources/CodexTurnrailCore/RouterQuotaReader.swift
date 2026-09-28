import Foundation

enum RouterQuotaAvailability: Equatable, Sendable {
  case available
  case exhausted
  case unavailable(RouterQuotaUnavailable)
}

enum RouterQuotaUnavailable: Equatable, Sendable {
  case timedOut
  case transport
  case httpStatus(Int)
  case invalidResponse

  var diagnostic: String {
    switch self {
    case .timedOut: "deadline exceeded"
    case .transport: "transport failure"
    case .httpStatus(let status): "HTTP \(status)"
    case .invalidResponse: "invalid quota response"
    }
  }
}

/// Optional quota reads use one waiting budget across all candidates in a selection.
///
/// Required credential and capability validation is outside this budget. Only time
/// spent waiting for quota consumes it; a later candidate cannot restart the budget.
struct RouterQuotaBudget {
  private var remaining: TimeInterval

  init(seconds: TimeInterval) { remaining = seconds }

  mutating func read(
    _ request: (DispatchTime) throws -> RouterQuotaAvailability
  ) rethrows -> RouterQuotaAvailability {
    guard remaining > 0 else { return .unavailable(.timedOut) }
    let started = DispatchTime.now()
    defer {
      remaining -=
        Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds)
        / 1_000_000_000
    }
    return try request(started + remaining)
  }
}

enum RouterQuotaReader {
  static func read(
    url: URL, credential: RouterCredential, deadline: DispatchTime
  ) throws -> RouterQuotaAvailability {
    var request = URLRequest(url: url)
    request.allHTTPHeaderFields = credential.headers.merging([
      "Accept": "application/json", "User-Agent": "codex-turnrail/1",
    ]) { _, new in new }
    let data: Data
    let status: Int
    do {
      (data, status) = try RouterHTTP.exchange(
        request, maximumBytes: 8 * 1024 * 1024, deadline: deadline)
    } catch is RouterHTTPDeadlineExceeded {
      return .unavailable(.timedOut)
    } catch {
      return .unavailable(.transport)
    }
    if status == 401 { throw RouterAccountUnavailable.loginRequired }
    guard status != 403 else {
      throw RouterFailure("The account service denied quota inspection (HTTP 403).")
    }
    guard status == 200 else { return .unavailable(.httpStatus(status)) }
    do {
      return try RouterAccounts.generalQuotaIsUsable(RouterJSON.object(data))
        ? .available : .exhausted
    } catch {
      return .unavailable(.invalidResponse)
    }
  }
}
