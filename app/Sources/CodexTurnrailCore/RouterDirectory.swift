import Darwin
import Foundation

enum RouterDirectory {
  static func canonical(_ path: String) throws -> URL {
    guard path.hasPrefix("/"), !path.contains("\0") else {
      throw RouterFailure("Routing requires an absolute working directory.")
    }
    let url = URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL
    guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw RouterFailure("The routing working directory does not exist.")
    }
    return url
  }

  static func accounts(cwd: String, routing: AccountRoutingConfiguration) throws -> [UUID] {
    let directory = try canonical(cwd)
    if let rule = matching(directory.path, routing: routing) { return rule.accountIDs }
    if let original = try originalCheckout(directory),
      let rule = matching(original.path, routing: routing)
    {
      return rule.accountIDs
    }
    return routing.defaultAccountIDs
  }

  private static func matching(_ path: String, routing: AccountRoutingConfiguration)
    -> DirectoryAccountRule?
  {
    routing.directoryRules.filter {
      path == $0.directory || path.hasPrefix($0.directory == "/" ? "/" : $0.directory + "/")
    }
    .max { $0.directory.count < $1.directory.count }
  }

  /// Inspect owned Git metadata directly, without evaluating repository configuration.
  static func originalCheckout(_ cwd: URL) throws -> URL? {
    var root = cwd
    while root.path != "/" {
      let git = root.appending(path: ".git")
      var directory: ObjCBool = false
      if FileManager.default.fileExists(atPath: git.path, isDirectory: &directory) {
        if directory.boolValue { return nil }
        let pointer = try ownedText(git)
        guard pointer.hasPrefix("gitdir: ") else {
          throw RouterFailure("Invalid linked-worktree Git pointer.")
        }
        let gitDirectory = resolve(String(pointer.dropFirst(8)), relativeTo: root)
        let common = resolve(
          try ownedText(gitDirectory.appending(path: "commondir")), relativeTo: gitDirectory)
        guard
          gitDirectory.deletingLastPathComponent().path == common.appending(path: "worktrees").path,
          common.lastPathComponent == ".git",
          resolve(try ownedText(gitDirectory.appending(path: "gitdir")), relativeTo: gitDirectory)
            .path == git.resolvingSymlinksInPath().path
        else {
          throw RouterFailure(
            "Linked-worktree metadata did not pass ownership and back-reference checks.")
        }
        _ = try ownedAttributes(common)
        let relative = String(cwd.path.dropFirst(root.path.count)).trimmingCharacters(
          in: CharacterSet(charactersIn: "/"))
        return common.deletingLastPathComponent().appending(path: relative).standardizedFileURL
      }
      root.deleteLastPathComponent()
    }
    return nil
  }

  private static func resolve(_ path: String, relativeTo parent: URL) -> URL {
    (path.hasPrefix("/") ? URL(filePath: path) : parent.appending(path: path))
      .resolvingSymlinksInPath().standardizedFileURL
  }

  private static func ownedAttributes(_ url: URL) throws -> [FileAttributeKey: Any] {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == geteuid()
    else {
      throw RouterFailure("Git routing metadata must belong to the current user.")
    }
    return attributes
  }

  private static func ownedText(_ url: URL) throws -> String {
    let attributes = try ownedAttributes(url)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      let size = attributes[.size] as? NSNumber, size.intValue <= 4096
    else {
      throw RouterFailure("Invalid Git routing metadata file.")
    }
    return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(
      in: .whitespacesAndNewlines)
  }
}
