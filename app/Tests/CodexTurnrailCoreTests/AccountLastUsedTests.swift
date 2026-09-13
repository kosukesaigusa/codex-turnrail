import Foundation
import Testing

@testable import CodexTurnrailCore

struct AccountLastUsedTests {
  @Test
  func keepsEachAccountDateAcrossReaderRestartsAndRemovesItWithTheAccount() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = UUID()
    let b = UUID()
    let store = AccountRegistryStore(rootURL: root)
    let aDirectory = try store.ensureAuthHome(forAccountID: a).deletingLastPathComponent()
    let bDirectory = try store.ensureAuthHome(forAccountID: b).deletingLastPathComponent()
    let reader = AccountLastUsedReader(rootURL: root)
    #expect(reader.read(accountID: a) == .neverUsed)
    #expect(reader.read(accountID: a).label(timeZone: .gmt) == "Last used: -")
    try record(accountID: a, timestamp: 1_789_099_140)
      .write(to: aDirectory.appending(path: "last-used.json"))
    try record(accountID: b, timestamp: 1_789_099_200)
      .write(to: bDirectory.appending(path: "last-used.json"))

    let restarted = AccountLastUsedReader(rootURL: root)
    #expect(restarted.read(accountID: a) == .used(Date(timeIntervalSince1970: 1_789_099_140)))
    #expect(restarted.read(accountID: b) == .used(Date(timeIntervalSince1970: 1_789_099_200)))
    try store.removeAuthHome(forAccountID: a)
    #expect(restarted.read(accountID: a) == .neverUsed)
    #expect(restarted.read(accountID: b) == .used(Date(timeIntervalSince1970: 1_789_099_200)))
  }

  @Test
  func formatsLocalCalendarDateWith24HourMinutes() throws {
    let date = Date(timeIntervalSince1970: 1_789_099_140)
    let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
    #expect(
      AccountLastUsedStatus.used(date).label(timeZone: tokyo) == "Last used: 2026-09-11 12:59")
    #expect(AccountLastUsedStatus.used(date).label(timeZone: .gmt) == "Last used: 2026-09-11 03:59")
  }

  @Test(arguments: ["malformed", "schema", "account", "negative", "overflow", "missing"])
  func corruptRecordsAreErrorsInsteadOfUnrecorded(_ kind: String) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let accountID = UUID()
    let directory = try AccountRegistryStore(rootURL: root)
      .ensureAuthHome(forAccountID: accountID).deletingLastPathComponent()
    var fields: [String: Any] = [
      "schemaVersion": 1,
      "accountId": accountID.uuidString,
      "startedAtUnixSeconds": 1_789_099_140,
    ]
    switch kind {
    case "schema": fields["schemaVersion"] = 2
    case "account": fields["accountId"] = UUID().uuidString
    case "negative": fields["startedAtUnixSeconds"] = -1
    case "overflow": fields["startedAtUnixSeconds"] = Int64.max
    case "missing": fields.removeValue(forKey: "startedAtUnixSeconds")
    case "malformed": break
    default: Issue.record("Unexpected test case")
    }
    let data =
      kind == "malformed" ? Data("{".utf8) : try JSONSerialization.data(withJSONObject: fields)
    try data.write(to: directory.appending(path: "last-used.json"))
    let status = AccountLastUsedReader(rootURL: root).read(accountID: accountID)
    guard case .failed = status else {
      Issue.record("Invalid metadata must show a read error")
      return
    }
    #expect(status.label(timeZone: .gmt) == "Last used: Read error")
  }

  private func record(accountID: UUID, timestamp: Int64) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1,
      "accountId": accountID.uuidString.lowercased(),
      "startedAtUnixSeconds": timestamp,
    ])
  }
}
