import Foundation

public struct AccountRateLimits: Equatable, Sendable {
  public let buckets: [AccountRateLimitBucket]

  public init(buckets: [AccountRateLimitBucket]) {
    self.buckets = buckets
  }
}

public struct AccountRateLimitBucket: Equatable, Identifiable, Sendable {
  public let limitID: String?
  public let name: String?
  public let primary: AccountRateLimitWindow?
  public let secondary: AccountRateLimitWindow?

  public init(
    limitID: String?,
    name: String?,
    primary: AccountRateLimitWindow?,
    secondary: AccountRateLimitWindow?
  ) {
    self.limitID = limitID
    self.name = name
    self.primary = primary
    self.secondary = secondary
  }

  public var id: String {
    limitID ?? "historical"
  }
}

public struct AccountRateLimitWindow: Equatable, Sendable {
  public let usedPercent: Int
  public let windowDurationMinutes: Int?
  public let resetsAt: Date?

  public init(
    usedPercent: Int,
    windowDurationMinutes: Int?,
    resetsAt: Date?
  ) throws {
    guard (0...100).contains(usedPercent) else {
      throw AccountReaderError.invalidUsage("usedPercent must be between 0 and 100")
    }
    if let windowDurationMinutes, windowDurationMinutes <= 0 {
      throw AccountReaderError.invalidUsage("windowDurationMins must be positive")
    }
    if let resetsAt, resetsAt.timeIntervalSince1970 <= 0 {
      throw AccountReaderError.invalidUsage("resetsAt must be a positive Unix timestamp")
    }
    self.usedPercent = usedPercent
    self.windowDurationMinutes = windowDurationMinutes
    self.resetsAt = resetsAt
  }

  public var remainingPercent: Int {
    100 - usedPercent
  }
}

public struct AccountUsageReader: Sendable {
  private let readRateLimits: @Sendable (URL, URL) async throws -> AccountRateLimits

  public init(
    readRateLimits: @escaping @Sendable (URL, URL) async throws -> AccountRateLimits
  ) {
    self.readRateLimits = readRateLimits
  }

  public func read(
    engineURL: URL,
    authHomeURL: URL
  ) async throws -> AccountRateLimits {
    try await readRateLimits(engineURL, authHomeURL)
  }

  public static let live = AccountUsageReader { engineURL, authHomeURL in
    try await Task.detached {
      let line = try AccountAppServerTransport.request(
        engineURL: engineURL,
        authHomeURL: authHomeURL,
        request: AccountUsageProtocol.rateLimitsReadRequest,
        responseID: 3
      )
      return try AccountUsageProtocol.parseRateLimitsResponse(line)
    }.value
  }
}

enum AccountUsageProtocol {
  static let rateLimitsReadRequest = #"{"id":3,"method":"account/rateLimits/read"}"#

  static func parseRateLimitsResponse(_ line: String) throws -> AccountRateLimits {
    guard let data = line.data(using: .utf8),
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      (object["id"] as? NSNumber)?.intValue == 3
    else {
      throw AccountReaderError.invalidResponse
    }
    if let error = object["error"] as? [String: Any] {
      throw AccountReaderError.serverError(
        try AccountServerFailureParser.parse(response: object, error: error)
      )
    }
    guard let result = object["result"] as? [String: Any],
      let historicalSnapshot = result["rateLimits"] as? [String: Any]
    else {
      throw AccountReaderError.invalidResponse
    }

    if let bucketValue = result["rateLimitsByLimitId"], !(bucketValue is NSNull) {
      guard let bucketValues = bucketValue as? [String: Any] else {
        throw AccountReaderError.invalidResponse
      }
      let buckets = try bucketValues.map { limitID, value in
        guard let snapshot = value as? [String: Any] else {
          throw AccountReaderError.invalidResponse
        }
        return try parseBucket(snapshot, explicitLimitID: limitID)
      }
      return AccountRateLimits(buckets: sortedBuckets(buckets))
    }

    return AccountRateLimits(
      buckets: [try parseBucket(historicalSnapshot, explicitLimitID: nil)]
    )
  }

  private static func parseBucket(
    _ snapshot: [String: Any],
    explicitLimitID: String?
  ) throws -> AccountRateLimitBucket {
    let responseLimitID = try optionalString(snapshot["limitId"])
    if let explicitLimitID, let responseLimitID, explicitLimitID != responseLimitID {
      throw AccountReaderError.invalidUsage(
        "rateLimitsByLimitId key does not match rateLimits.limitId"
      )
    }
    return AccountRateLimitBucket(
      limitID: explicitLimitID ?? responseLimitID,
      name: try optionalString(snapshot["limitName"]),
      primary: try optionalWindow(snapshot["primary"]),
      secondary: try optionalWindow(snapshot["secondary"])
    )
  }

  private static func optionalWindow(_ value: Any?) throws -> AccountRateLimitWindow? {
    guard let value, !(value is NSNull) else {
      return nil
    }
    guard let object = value as? [String: Any] else {
      throw AccountReaderError.invalidResponse
    }
    let usedPercent = try requiredInteger(object["usedPercent"])
    let duration = try optionalPositiveInteger(
      object["windowDurationMins"],
      field: "windowDurationMins"
    )
    let resetTimestamp = try optionalPositiveInteger(object["resetsAt"], field: "resetsAt")
    return try AccountRateLimitWindow(
      usedPercent: usedPercent,
      windowDurationMinutes: duration,
      resetsAt: resetTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    )
  }

  private static func optionalPositiveInteger(_ value: Any?, field: String) throws -> Int? {
    guard let value, !(value is NSNull) else {
      return nil
    }
    let integer = try requiredInteger(value)
    guard integer > 0 else {
      throw AccountReaderError.invalidUsage("\(field) must be positive")
    }
    return integer
  }

  private static func requiredInteger(_ value: Any?) throws -> Int {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else {
      throw AccountReaderError.invalidResponse
    }
    let double = number.doubleValue
    guard double.isFinite,
      double.rounded(.towardZero) == double,
      double >= Double(Int.min),
      double <= Double(Int.max)
    else {
      throw AccountReaderError.invalidResponse
    }
    return Int(double)
  }

  private static func optionalString(_ value: Any?) throws -> String? {
    guard let value, !(value is NSNull) else {
      return nil
    }
    guard let string = value as? String else {
      throw AccountReaderError.invalidResponse
    }
    return string
  }

  private static func sortedBuckets(_ buckets: [AccountRateLimitBucket])
    -> [AccountRateLimitBucket]
  {
    buckets.sorted { left, right in
      if left.limitID == "codex" {
        return right.limitID != "codex"
      }
      if right.limitID == "codex" {
        return false
      }
      return (left.name ?? left.limitID ?? "") < (right.name ?? right.limitID ?? "")
    }
  }
}
