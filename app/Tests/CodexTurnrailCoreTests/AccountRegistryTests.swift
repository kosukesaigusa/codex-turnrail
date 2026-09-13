import Foundation
import Testing

@testable import CodexTurnrailCore

struct AccountRegistryTests {
  @Test
  func persistsVerifiedAccountsWithoutGrantingRoutingPermission() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AccountRegistryStore(rootURL: root)
    let initial = try store.loadOrInitialize()
    #expect(initial == .empty)
    let id = UUID()
    let registered = try store.registerAccount(
      identity: ChatGPTAccountIdentity(email: "PERSON@example.com", planType: .pro),
      to: initial, id: id
    )
    #expect(
      registered
        == AccountRegistryState(
          schemaVersion: 3, revision: 1,
          accounts: [try TurnrailAccount(id: id, email: "person@example.com", planType: .pro)],
          routing: .empty
        ))
    #expect(registered.accounts[0].displayName == "person@example.com (Pro)")
    #expect(try AccountRegistryStore(rootURL: root).loadOrInitialize() == registered)
  }

  @Test
  func rejectsDuplicateVerifiedEmailsAndMismatchedReauthentication() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AccountRegistryStore(rootURL: root)
    let id = UUID()
    let state = try store.registerAccount(
      identity: ChatGPTAccountIdentity(email: "person@example.com", planType: .plus),
      to: store.loadOrInitialize(), id: id
    )
    #expect(throws: AccountRegistryError.duplicateEmail("person@example.com")) {
      try store.registerAccount(
        identity: ChatGPTAccountIdentity(email: "PERSON@example.com", planType: .pro), to: state
      )
    }
    #expect(
      throws: AccountRegistryError.identityMismatch(
        expected: "person@example.com", actual: "other@example.com"
      )
    ) {
      try store.updateIdentity(
        ChatGPTAccountIdentity(email: "other@example.com", planType: .pro), for: id, in: state
      )
    }
    let refreshed = try store.updateIdentity(
      ChatGPTAccountIdentity(email: "person@example.com", planType: .pro), for: id, in: state
    )
    #expect(
      refreshed.accounts == [
        try TurnrailAccount(id: id, email: "person@example.com", planType: .pro)
      ])
    #expect(refreshed.revision == 2)
    #expect(refreshed.routing == state.routing)
  }

  @Test
  func rejectsDuplicateAccountIDsAndUnsupportedSchema() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AccountRegistryStore(rootURL: root)
    let id = UUID()
    let accounts = [
      try TurnrailAccount(id: id, email: "a@example.com", planType: .pro),
      try TurnrailAccount(id: id, email: "b@example.com", planType: .plus),
    ]
    for (version, expected) in [
      (3, AccountRegistryError.duplicateAccountID(id)),
      (2, AccountRegistryError.unsupportedSchemaVersion(2)),
    ] {
      let invalid = AccountRegistryState(
        schemaVersion: version, revision: 1, accounts: accounts, routing: .empty)
      #expect(throws: expected) {
        try store.updateRouting(.empty, in: invalid)
      }
    }
  }

  @Test
  func removesAnAccountFromEveryRuleAndPreservesRemainingPriority() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AccountRegistryStore(rootURL: root)
    let a = UUID()
    let b = UUID()
    var state = try store.registerAccount(
      identity: ChatGPTAccountIdentity(email: "a@example.com", planType: .pro),
      to: store.loadOrInitialize(), id: a
    )
    state = try store.registerAccount(
      identity: ChatGPTAccountIdentity(email: "b@example.com", planType: .team), to: state, id: b
    )
    let rule = DirectoryAccountRule(id: UUID(), directory: root.path, accountIDs: [b, a])
    state = try store.updateRouting(
      AccountRoutingConfiguration(defaultAccountIDs: [a, b], directoryRules: [rule]), in: state
    )
    let removed = try store.removeAccount(id: a, from: state)
    #expect(
      removed.routing
        == AccountRoutingConfiguration(
          defaultAccountIDs: [b],
          directoryRules: [DirectoryAccountRule(id: rule.id, directory: root.path, accountIDs: [b])]
        ))
    #expect(removed.accounts.map(\.id) == [b])
    #expect(try store.loadOrInitialize() == removed)
  }

  @Test
  func createsAuthenticationHomeOnDemand() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AccountRegistryStore(rootURL: root)
    let id = UUID()
    let home = try store.ensureAuthHome(forAccountID: id)
    #expect(try home.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    try store.removeAuthHome(forAccountID: id)
    #expect(!FileManager.default.fileExists(atPath: home.path))
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  }
}
