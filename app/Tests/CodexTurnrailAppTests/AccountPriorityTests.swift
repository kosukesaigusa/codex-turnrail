import CodexTurnrailCore
import Foundation
import Testing

@testable import CodexTurnrailApp

@MainActor
struct AccountPriorityTests {
  @Test
  func reorderingChangesOnlyTheChosenFolderAndSurvivesReload() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AccountRegistryStore(rootURL: root)
    var state = try store.loadOrInitialize()
    for email in ["first@example.com", "second@example.com", "third@example.com"] {
      state = try store.registerAccount(
        identity: ChatGPTAccountIdentity(email: email, planType: .pro), to: state)
    }
    let accounts = state.accounts
    let ids = accounts.map(\.id)
    let work = DirectoryAccountRule(id: UUID(), directory: "/Projects/work", accountIDs: ids)
    let personal = DirectoryAccountRule(
      id: UUID(), directory: "/Projects/personal", accountIDs: [ids[2], ids[0]])
    state = try store.updateRouting(
      AccountRoutingConfiguration(
        defaultAccountIDs: [ids[1], ids[2]], directoryRules: [work, personal]), in: state)
    let model = TurnrailViewModel(
      engineURLResult: .failure(PriorityTestError.unexpectedOperation),
      routerURLResult: .failure(PriorityTestError.unexpectedOperation),
      registryStoreResult: .success(store),
      commandExecutor: CommandExecutor { _, _, _ in throw PriorityTestError.unexpectedOperation },
      loginExecutor: AccountLoginExecutor { _ in throw PriorityTestError.unexpectedOperation },
      compatibilityProbe: { _, _ in throw PriorityTestError.unexpectedOperation },
      isApplicationRunning: { false },
      identityReader: AccountIdentityReader { _, _ in throw PriorityTestError.unexpectedOperation },
      usageReader: AccountUsageReader { _, _ in throw PriorityTestError.unexpectedOperation })

    model.moveAccount(id: ids[2], direction: .up, scope: .directory(work.id))
    #expect(model.accountError == nil)
    #expect(
      try model.registryState.routing.accountIDs(in: .directory(work.id)) == [
        ids[0], ids[2], ids[1],
      ])
    #expect(model.registryState.routing.directoryRules[1] == personal)
    #expect(model.registryState.routing.defaultAccountIDs == [ids[1], ids[2]])

    model.moveAccount(id: ids[2], direction: .down, scope: .directory(work.id))
    #expect(model.registryState.routing == state.routing)
    model.moveAccount(id: ids[2], direction: .up, scope: .defaultRule)
    #expect(model.accountError == nil)
    #expect(model.registryState.routing.defaultAccountIDs == [ids[2], ids[1]])
    #expect(model.registryState.routing.directoryRules == [work, personal])
    #expect(model.registryState.accounts == accounts)
    #expect(try AccountRegistryStore(rootURL: root).loadOrInitialize() == model.registryState)
  }
}

private enum PriorityTestError: Error { case unexpectedOperation }
