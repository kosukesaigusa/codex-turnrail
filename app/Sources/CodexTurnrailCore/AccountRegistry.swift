import Foundation

public enum ChatGPTPlan: String, Codable, Equatable, Sendable {
  case free
  case go
  case plus
  case pro
  case proLite = "prolite"
  case team
  case selfServeBusinessProLite = "self_serve_business_prolite"
  case selfServeBusinessUsageBased = "self_serve_business_usage_based"
  case business
  case ent26
  case enterpriseCBPAutomation = "enterprise_cbp_automation"
  case enterpriseCBPUsageBased = "enterprise_cbp_usage_based"
  case enterprise
  case edu
  case eduPlus = "edu_plus"
  case eduPro = "edu_pro"
  case unknown

  public var displayName: String {
    switch self {
    case .free:
      "Free"
    case .go:
      "Go"
    case .plus:
      "Plus"
    case .pro:
      "Pro"
    case .proLite:
      "Pro Lite"
    case .team:
      "Team"
    case .selfServeBusinessProLite:
      "Business Pro Lite"
    case .selfServeBusinessUsageBased:
      "Business Usage Based"
    case .business:
      "Business"
    case .ent26, .enterpriseCBPAutomation, .enterpriseCBPUsageBased, .enterprise:
      "Enterprise"
    case .edu:
      "Education"
    case .eduPlus:
      "Education Plus"
    case .eduPro:
      "Education Pro"
    case .unknown:
      "Unknown plan"
    }
  }
}

public struct ChatGPTAccountIdentity: Codable, Equatable, Sendable {
  public let email: String
  public let planType: ChatGPTPlan

  public init(email: String, planType: ChatGPTPlan) throws {
    self.email = try AccountIdentityValidation.validatedEmail(email)
    self.planType = planType
  }
}

public struct TurnrailAccount: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let email: String
  public let planType: ChatGPTPlan

  public init(id: UUID, email: String, planType: ChatGPTPlan) throws {
    self.id = id
    self.email = try AccountIdentityValidation.validatedEmail(email)
    self.planType = planType
  }

  public var displayName: String {
    "\(email) (\(planType.displayName))"
  }
}

public enum AccountMoveDirection: Equatable, Sendable {
  case up
  case down
}

public struct AccountRegistryState: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 3

  public let schemaVersion: Int
  public let revision: UInt64
  public let accounts: [TurnrailAccount]
  public let routing: AccountRoutingConfiguration

  public init(
    schemaVersion: Int,
    revision: UInt64,
    accounts: [TurnrailAccount],
    routing: AccountRoutingConfiguration
  ) {
    self.schemaVersion = schemaVersion
    self.revision = revision
    self.accounts = accounts
    self.routing = routing
  }

  public static let empty = AccountRegistryState(
    schemaVersion: currentSchemaVersion,
    revision: 0,
    accounts: [],
    routing: .empty
  )
}

public enum AccountRegistryError: LocalizedError, Equatable {
  case unsupportedSchemaVersion(Int)
  case invalidEmail
  case duplicateEmail(String)
  case duplicateAccountID(UUID)
  case unknownAccount(UUID)
  case identityMismatch(expected: String, actual: String)
  case cannotMoveAccount(UUID, AccountMoveDirection)
  case revisionOverflow

  public var errorDescription: String? {
    switch self {
    case .unsupportedSchemaVersion(let version):
      "Account registry schema version \(version) is not supported."
    case .invalidEmail:
      "ChatGPT did not return a valid account email address."
    case .duplicateEmail(let email):
      "\(email) is already connected."
    case .duplicateAccountID(let id):
      "Account registry contains duplicate account ID \(id.uuidString)."
    case .unknownAccount(let id):
      "Account \(id.uuidString) does not exist."
    case .identityMismatch(let expected, let actual):
      "Expected \(expected), but ChatGPT logged in as \(actual)."
    case .cannotMoveAccount(let id, let direction):
      "Account \(id.uuidString) cannot move \(direction == .up ? "up" : "down")."
    case .revisionOverflow:
      "Account registry revision reached its maximum value."
    }
  }
}

public struct AccountRegistryStore {
  public let rootURL: URL

  private let fileManager: FileManager
  private let decoder: JSONDecoder
  private let encoder: JSONEncoder

  public init(rootURL: URL, fileManager: FileManager = .default) {
    self.rootURL = rootURL
    self.fileManager = fileManager
    decoder = JSONDecoder()
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  }

  public var stateURL: URL {
    rootURL.appending(path: "state.json")
  }

  public func loadOrInitialize() throws -> AccountRegistryState {
    if !fileManager.fileExists(atPath: stateURL.path) {
      try save(.empty)
      return .empty
    }

    let data = try Data(contentsOf: stateURL)
    struct SchemaHeader: Decodable { let schemaVersion: Int }
    let header = try decoder.decode(SchemaHeader.self, from: data)
    guard header.schemaVersion == AccountRegistryState.currentSchemaVersion else {
      throw AccountRegistryError.unsupportedSchemaVersion(header.schemaVersion)
    }
    let state = try decoder.decode(AccountRegistryState.self, from: data)
    try validate(state)
    return state
  }

  public func registerAccount(
    identity: ChatGPTAccountIdentity,
    to state: AccountRegistryState,
    id: UUID = UUID()
  ) throws -> AccountRegistryState {
    try validate(state)
    guard
      !state.accounts.contains(where: {
        $0.email.caseInsensitiveCompare(identity.email) == .orderedSame
      })
    else {
      throw AccountRegistryError.duplicateEmail(identity.email)
    }

    let account = try TurnrailAccount(
      id: id,
      email: identity.email,
      planType: identity.planType
    )
    let updated = AccountRegistryState(
      schemaVersion: AccountRegistryState.currentSchemaVersion,
      revision: try nextRevision(after: state.revision),
      accounts: state.accounts + [account],
      routing: state.routing
    )
    try save(updated)
    return updated
  }

  public func updateIdentity(
    _ identity: ChatGPTAccountIdentity,
    for id: UUID,
    in state: AccountRegistryState
  ) throws -> AccountRegistryState {
    try validate(state)
    guard let index = state.accounts.firstIndex(where: { $0.id == id }) else {
      throw AccountRegistryError.unknownAccount(id)
    }
    let existing = state.accounts[index]
    guard existing.email == identity.email else {
      throw AccountRegistryError.identityMismatch(
        expected: existing.email,
        actual: identity.email
      )
    }
    let refreshed = try TurnrailAccount(
      id: existing.id,
      email: identity.email,
      planType: identity.planType
    )
    guard refreshed != existing else {
      return state
    }

    var accounts = state.accounts
    accounts[index] = refreshed
    let updated = AccountRegistryState(
      schemaVersion: AccountRegistryState.currentSchemaVersion,
      revision: try nextRevision(after: state.revision),
      accounts: accounts,
      routing: state.routing
    )
    try save(updated)
    return updated
  }

  public func updateRouting(
    _ routing: AccountRoutingConfiguration,
    in state: AccountRegistryState
  ) throws -> AccountRegistryState {
    try validate(state)
    guard state.routing != routing else {
      return state
    }
    let updated = AccountRegistryState(
      schemaVersion: AccountRegistryState.currentSchemaVersion,
      revision: try nextRevision(after: state.revision),
      accounts: state.accounts,
      routing: routing
    )
    try save(updated)
    return updated
  }

  public func removeAccount(
    id: UUID,
    from state: AccountRegistryState
  ) throws -> AccountRegistryState {
    try validate(state)
    guard state.accounts.contains(where: { $0.id == id }) else {
      throw AccountRegistryError.unknownAccount(id)
    }

    let updated = AccountRegistryState(
      schemaVersion: AccountRegistryState.currentSchemaVersion,
      revision: try nextRevision(after: state.revision),
      accounts: state.accounts.filter { $0.id != id },
      routing: state.routing.removingAccount(id: id)
    )
    try save(updated)
    return updated
  }

  public func authHomeURL(forAccountID id: UUID) -> URL {
    rootURL
      .appending(path: "accounts")
      .appending(path: id.uuidString.lowercased())
      .appending(path: "auth-home")
  }

  public func ensureAuthHome(forAccountID id: UUID) throws -> URL {
    let authHomeURL = authHomeURL(forAccountID: id)
    try fileManager.createDirectory(at: authHomeURL, withIntermediateDirectories: true)
    return authHomeURL
  }

  public func removeAuthHome(forAccountID id: UUID) throws {
    let accountRootURL = authHomeURL(forAccountID: id).deletingLastPathComponent()
    guard fileManager.fileExists(atPath: accountRootURL.path) else {
      return
    }
    try fileManager.removeItem(at: accountRootURL)
  }

  private func save(_ state: AccountRegistryState) throws {
    try validate(state)
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try encoder.encode(state).write(to: stateURL, options: .atomic)
  }

  private func validate(_ state: AccountRegistryState) throws {
    guard state.schemaVersion == AccountRegistryState.currentSchemaVersion else {
      throw AccountRegistryError.unsupportedSchemaVersion(state.schemaVersion)
    }
    var accountIDs = Set<UUID>()
    var accountEmails = Set<String>()
    for account in state.accounts {
      guard try AccountIdentityValidation.validatedEmail(account.email) == account.email else {
        throw AccountRegistryError.invalidEmail
      }
      guard accountIDs.insert(account.id).inserted else {
        throw AccountRegistryError.duplicateAccountID(account.id)
      }
      guard accountEmails.insert(account.email).inserted else {
        throw AccountRegistryError.duplicateEmail(account.email)
      }
    }
    try state.routing.validate(knownAccountIDs: accountIDs)
  }

  private func nextRevision(after revision: UInt64) throws -> UInt64 {
    let (next, overflow) = revision.addingReportingOverflow(1)
    guard !overflow else {
      throw AccountRegistryError.revisionOverflow
    }
    return next
  }
}

enum AccountIdentityValidation {
  static func validatedEmail(_ rawEmail: String) throws -> String {
    let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let components = email.split(separator: "@", omittingEmptySubsequences: false)
    guard components.count == 2, !components[0].isEmpty, !components[1].isEmpty else {
      throw AccountRegistryError.invalidEmail
    }
    return email
  }
}

public enum TurnrailApplicationSupport {
  public static func rootURL(fileManager: FileManager = .default) throws -> URL {
    let applicationSupportURLs = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )
    guard applicationSupportURLs.count == 1,
      let applicationSupportURL = applicationSupportURLs.first
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    return applicationSupportURL.appending(path: "Codex Turnrail")
  }
}
