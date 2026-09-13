import Foundation

public enum AccountRoutingScope: Hashable, Sendable {
  case defaultRule
  case directory(UUID)
}

public struct DirectoryAccountRule: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var directory: String
  public var accountIDs: [UUID]

  public init(id: UUID, directory: String, accountIDs: [UUID]) {
    self.id = id
    self.directory = directory
    self.accountIDs = accountIDs
  }
}

/// Ordered account lists define both permission and priority for each scope.
public struct AccountRoutingConfiguration: Codable, Equatable, Sendable {
  public var defaultAccountIDs: [UUID]
  public var directoryRules: [DirectoryAccountRule]

  public init(defaultAccountIDs: [UUID], directoryRules: [DirectoryAccountRule]) {
    self.defaultAccountIDs = defaultAccountIDs
    self.directoryRules = directoryRules
  }

  public static let empty = AccountRoutingConfiguration(
    defaultAccountIDs: [], directoryRules: []
  )

  public var allAllowedAccountIDs: Set<UUID> {
    Set(defaultAccountIDs + directoryRules.flatMap(\.accountIDs))
  }

  public func accountIDs(in scope: AccountRoutingScope) throws -> [UUID] {
    switch scope {
    case .defaultRule:
      return defaultAccountIDs
    case .directory(let id):
      guard let rule = directoryRules.first(where: { $0.id == id }) else {
        throw AccountRoutingError.unknownRule(id)
      }
      return rule.accountIDs
    }
  }

  public func settingAllowed(
    _ allowed: Bool, accountID: UUID, in scope: AccountRoutingScope
  ) throws -> Self {
    var ids = try accountIDs(in: scope).filter { $0 != accountID }
    if allowed {
      let existing = try accountIDs(in: scope)
      ids = existing.contains(accountID) ? existing : existing + [accountID]
    }
    return try replacingAccountIDs(ids, in: scope)
  }

  public func prioritizing(accountID: UUID, in scope: AccountRoutingScope) throws -> Self {
    let ids = try accountIDs(in: scope)
    guard ids.contains(accountID) else {
      throw AccountRoutingError.accountNotAllowed(accountID)
    }
    return try replacingAccountIDs([accountID] + ids.filter { $0 != accountID }, in: scope)
  }

  public func moving(
    accountID: UUID, direction: AccountMoveDirection, in scope: AccountRoutingScope
  ) throws -> Self {
    var ids = try accountIDs(in: scope)
    guard let source = ids.firstIndex(of: accountID) else {
      throw AccountRoutingError.accountNotAllowed(accountID)
    }
    let destination = direction == .up ? source - 1 : source + 1
    guard ids.indices.contains(destination) else {
      throw AccountRegistryError.cannotMoveAccount(accountID, direction)
    }
    ids.swapAt(source, destination)
    return try replacingAccountIDs(ids, in: scope)
  }

  public func addingDirectory(_ url: URL, id: UUID) throws -> Self {
    let directory = try Self.directoryPath(url)
    var updated = self
    updated.directoryRules.append(
      DirectoryAccountRule(id: id, directory: directory, accountIDs: [])
    )
    return updated
  }

  public func changingDirectory(id: UUID, to url: URL) throws -> Self {
    guard let index = directoryRules.firstIndex(where: { $0.id == id }) else {
      throw AccountRoutingError.unknownRule(id)
    }
    var updated = self
    updated.directoryRules[index].directory = try Self.directoryPath(url)
    return updated
  }

  public func removingDirectory(id: UUID) throws -> Self {
    guard directoryRules.contains(where: { $0.id == id }) else {
      throw AccountRoutingError.unknownRule(id)
    }
    var updated = self
    updated.directoryRules.removeAll { $0.id == id }
    return updated
  }

  public func removingAccount(id: UUID) -> Self {
    Self(
      defaultAccountIDs: defaultAccountIDs.filter { $0 != id },
      directoryRules: directoryRules.map { rule in
        DirectoryAccountRule(
          id: rule.id, directory: rule.directory, accountIDs: rule.accountIDs.filter { $0 != id }
        )
      }
    )
  }

  public func validate(knownAccountIDs: Set<UUID>) throws {
    var ruleIDs = Set<UUID>()
    var directories = Set<String>()
    for rule in directoryRules {
      guard ruleIDs.insert(rule.id).inserted else {
        throw AccountRoutingError.duplicateRule(rule.id)
      }
      guard rule.directory.hasPrefix("/"),
        URL(filePath: rule.directory).standardizedFileURL.path == rule.directory
      else {
        throw AccountRoutingError.invalidDirectory(rule.directory)
      }
      guard directories.insert(rule.directory).inserted else {
        throw AccountRoutingError.duplicateDirectory(rule.directory)
      }
    }
    for ids in [defaultAccountIDs] + directoryRules.map(\.accountIDs) {
      var seen = Set<UUID>()
      for id in ids {
        guard knownAccountIDs.contains(id) else {
          throw AccountRegistryError.unknownAccount(id)
        }
        guard seen.insert(id).inserted else {
          throw AccountRoutingError.duplicateAccount(id)
        }
      }
    }
  }

  private func replacingAccountIDs(_ ids: [UUID], in scope: AccountRoutingScope) throws -> Self {
    var updated = self
    switch scope {
    case .defaultRule:
      updated.defaultAccountIDs = ids
    case .directory(let id):
      guard let index = directoryRules.firstIndex(where: { $0.id == id }) else {
        throw AccountRoutingError.unknownRule(id)
      }
      updated.directoryRules[index].accountIDs = ids
    }
    return updated
  }

  private static func directoryPath(_ url: URL) throws -> String {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    guard url.isFileURL,
      try resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    else {
      throw AccountRoutingError.invalidDirectory(url.path)
    }
    return resolved.path
  }
}

public enum AccountRoutingError: LocalizedError, Equatable {
  case unknownRule(UUID)
  case duplicateRule(UUID)
  case invalidDirectory(String)
  case duplicateDirectory(String)
  case duplicateAccount(UUID)
  case accountNotAllowed(UUID)

  public var errorDescription: String? {
    switch self {
    case .unknownRule(let id):
      "Directory rule \(id) does not exist."
    case .duplicateRule(let id):
      "Directory rule \(id) occurs more than once."
    case .invalidDirectory(let path):
      "Choose an existing directory with an absolute path: \(path)"
    case .duplicateDirectory(let path):
      "A rule already exists for \(path)."
    case .duplicateAccount(let id):
      "Account \(id) occurs more than once in a rule."
    case .accountNotAllowed:
      "This account is not allowed by the selected rule."
    }
  }
}
