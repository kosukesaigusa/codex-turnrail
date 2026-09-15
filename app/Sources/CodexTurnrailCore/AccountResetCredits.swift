import Foundation

/// The server's available count and optional detail list from the same usage read.
public struct AccountResetCredits: Decodable, Equatable, Sendable {
  public let availableCount: Int
  public let credits: [AccountResetCredit]?

  public init(availableCount: Int, credits: [AccountResetCredit]?) throws {
    guard availableCount >= 0 else {
      throw AccountReaderError.invalidUsage("availableCount must not be negative")
    }
    if let credits {
      guard Set(credits.map(\.id)).count == credits.count else {
        throw AccountReaderError.invalidUsage("Reset credit IDs must be unique")
      }
      guard credits.filter({ $0.status == .available }).count <= availableCount else {
        throw AccountReaderError.invalidUsage("Reset details exceed the available count")
      }
    }
    self.availableCount = availableCount
    self.credits = credits
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      availableCount: values.decode(Int.self, forKey: .availableCount),
      credits: values.decodeIfPresent([AccountResetCredit].self, forKey: .credits)
    )
  }

  /// Nil preserves an unavailable detail lookup; a shorter list preserves a capped response.
  public var availableCredits: [AccountResetCredit]? {
    credits.map { items in
      items.filter { $0.status == .available }.sorted { left, right in
        switch (left.expiresAt, right.expiresAt) {
        case (.some(let lhs), .some(let rhs)) where lhs != rhs: return lhs < rhs
        case (.some, .none): return true
        case (.none, .some): return false
        default: return left.id < right.id
        }
      }
    }
  }

  private enum CodingKeys: String, CodingKey {
    case availableCount, credits
  }
}

public struct AccountResetCredit: Decodable, Equatable, Identifiable, Sendable {
  public enum ResetType: String, Decodable, Sendable {
    case codexRateLimits, unknown
  }

  public enum Status: String, Decodable, Sendable {
    case available, redeeming, redeemed, unknown
  }

  public let id: String
  public let resetType: ResetType
  public let status: Status
  public let grantedAt: Date
  public let expiresAt: Date?
  public let title: String?

  public var displayTitle: String {
    if let title { return title }
    switch resetType {
    case .codexRateLimits: return "Full reset"
    case .unknown: return "Unknown reset"
    }
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    guard !id.isEmpty else {
      throw AccountReaderError.invalidUsage("Reset credit ID must not be empty")
    }
    resetType = try values.decode(ResetType.self, forKey: .resetType)
    status = try values.decode(Status.self, forKey: .status)
    grantedAt = try Self.timestamp(values.decode(Int64.self, forKey: .grantedAt))
    guard values.contains(.expiresAt) else {
      throw DecodingError.keyNotFound(
        CodingKeys.expiresAt,
        DecodingError.Context(
          codingPath: values.codingPath, debugDescription: "Missing reset expiry"))
    }
    expiresAt = try values.decodeIfPresent(Int64.self, forKey: .expiresAt).map(Self.timestamp)
    title = try values.decodeIfPresent(String.self, forKey: .title)
  }

  private static func timestamp(_ seconds: Int64) throws -> Date {
    guard (0...253_402_300_799).contains(seconds) else {
      throw AccountReaderError.invalidUsage("Reset credit timestamp is out of range")
    }
    return Date(timeIntervalSince1970: Double(seconds))
  }

  private enum CodingKeys: String, CodingKey {
    case id, resetType, status, grantedAt, expiresAt, title
  }
}
