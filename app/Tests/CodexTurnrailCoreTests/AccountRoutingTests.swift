import Foundation
import Testing

@testable import CodexTurnrailCore

struct AccountRoutingTests {
  @Test
  func permissionAndPriorityChangesStayWithinTheirRuleAndSurviveReload() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AccountRegistryStore(rootURL: root)
    let a = UUID()
    let b = UUID()
    let c = UUID()
    var state = try store.loadOrInitialize()
    for (id, email, plan) in [
      (a, "a@example.com", ChatGPTPlan.pro), (b, "b@example.com", .pro),
      (c, "c@example.com", .team),
    ] {
      state = try store.registerAccount(
        identity: ChatGPTAccountIdentity(email: email, planType: plan), to: state, id: id)
    }
    let ruleID = UUID()
    let scope = AccountRoutingScope.directory(ruleID)
    let routing = AccountRoutingConfiguration(
      defaultAccountIDs: [a, b],
      directoryRules: [
        DirectoryAccountRule(id: ruleID, directory: root.path, accountIDs: [c, a, b])
      ])
    state = try store.updateRouting(routing, in: state)
    let switched = try routing.prioritizing(accountID: b, in: scope)
    #expect(
      switched
        == AccountRoutingConfiguration(
          defaultAccountIDs: [a, b],
          directoryRules: [
            DirectoryAccountRule(id: ruleID, directory: root.path, accountIDs: [b, c, a])
          ]))
    #expect(throws: AccountRoutingError.accountNotAllowed(c)) {
      try routing.prioritizing(accountID: c, in: .defaultRule)
    }
    let moved = try switched.moving(accountID: a, direction: .up, in: scope)
    #expect(try moved.accountIDs(in: scope) == [b, a, c])
    let disabled = try moved.settingAllowed(false, accountID: c, in: scope)
    #expect(try disabled.accountIDs(in: scope) == [b, a])
    #expect(try disabled.settingAllowed(true, accountID: c, in: scope) == moved)
    #expect(try disabled.settingAllowed(true, accountID: b, in: scope) == disabled)
    #expect(throws: AccountRegistryError.cannotMoveAccount(b, .up)) {
      try disabled.moving(accountID: b, direction: .up, in: scope)
    }
    state = try store.updateRouting(disabled, in: state)
    #expect(try AccountRegistryStore(rootURL: root).loadOrInitialize() == state)
    #expect(try store.updateRouting(disabled, in: state).revision == state.revision)
  }

  @Test
  func validatesTheWholeRuleSetBeforeSavingAndLeavesThePreviousStateIntact() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AccountRegistryStore(rootURL: root)
    let a = UUID()
    let state = try store.registerAccount(
      identity: ChatGPTAccountIdentity(email: "a@example.com", planType: .team),
      to: store.loadOrInitialize(), id: a
    )
    let rule = DirectoryAccountRule(id: UUID(), directory: root.path, accountIDs: [a])
    let invalid: [AccountRoutingConfiguration] = [
      .init(defaultAccountIDs: [UUID()], directoryRules: []),
      .init(defaultAccountIDs: [a, a], directoryRules: []),
      .init(defaultAccountIDs: [], directoryRules: [rule, rule]),
      .init(
        defaultAccountIDs: [],
        directoryRules: [rule, .init(id: UUID(), directory: root.path, accountIDs: [])]),
      .init(
        defaultAccountIDs: [],
        directoryRules: [.init(id: UUID(), directory: "relative/path", accountIDs: [a])]),
      .init(
        defaultAccountIDs: [],
        directoryRules: [.init(id: UUID(), directory: "/a/../b", accountIDs: [a])]),
    ]
    for routing in invalid {
      #expect(throws: (any Error).self) { try store.updateRouting(routing, in: state) }
      #expect(try store.loadOrInitialize() == state)
    }
    let bytes = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 3, "revision": 0, "accounts": [],
    ])
    try bytes.write(to: store.stateURL)
    #expect(throws: (any Error).self) { try store.loadOrInitialize() }
  }

  @Test
  func directoryEditingResolvesSymlinksAndDoesNotGrantAccountsAutomatically() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appending(path: "project")
    let alias = root.appending(path: "alias")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
    let id = UUID()
    let added = try AccountRoutingConfiguration.empty.addingDirectory(alias, id: id)
    #expect(
      added.directoryRules == [
        .init(id: id, directory: project.resolvingSymlinksInPath().path, accountIDs: [])
      ])
    let changed = try added.changingDirectory(id: id, to: root)
    #expect(changed.directoryRules[0].directory == root.resolvingSymlinksInPath().path)
    #expect(try changed.removingDirectory(id: id) == .empty)
    #expect(throws: AccountRoutingError.unknownRule(id)) {
      try AccountRoutingConfiguration.empty.accountIDs(in: .directory(id))
    }
  }
}
