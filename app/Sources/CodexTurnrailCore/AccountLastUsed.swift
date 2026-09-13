import Foundation

public enum AccountLastUsedStatus: Equatable, Sendable {
  case neverUsed
  case used(Date)
  case failed(String)

  public func label(timeZone: TimeZone) -> String {
    switch self {
    case .neverUsed:
      return "Last used: -"
    case .used(let date):
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.timeZone = timeZone
      formatter.dateFormat = "yyyy-MM-dd HH:mm"
      return "Last used: \(formatter.string(from: date))"
    case .failed:
      return "Last used: Read error"
    }
  }
}

public struct AccountLastUsedReader {
  private let rootURL: URL

  public init(rootURL: URL) {
    self.rootURL = rootURL
  }

  public func read(accountID: UUID) -> AccountLastUsedStatus {
    let url = rootURL.appending(path: "accounts")
      .appending(path: accountID.uuidString.lowercased())
      .appending(path: "last-used.json")
    do {
      let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
      guard record.schemaVersion == 1,
        record.accountId == accountID,
        (0...253_402_300_799).contains(record.startedAtUnixSeconds)
      else {
        return .failed("The account Last used record has invalid fields.")
      }
      return .used(Date(timeIntervalSince1970: Double(record.startedAtUnixSeconds)))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return .neverUsed
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  private struct Record: Decodable {
    let schemaVersion: Int
    let accountId: UUID
    let startedAtUnixSeconds: Int64
  }
}
