import Foundation

public enum RouterPathResolverError: LocalizedError, Equatable {
  case packagedResourcesUnavailable
  case developmentPathMissing
  case pathIsNotAbsolute(String)
  case routerIsNotExecutable(String)

  public var errorDescription: String? {
    switch self {
    case .packagedResourcesUnavailable:
      "The packaged app does not expose a MacOS directory."
    case .developmentPathMissing:
      "Set CODEX_TURNRAIL_ROUTER_PATH to run the development app."
    case .pathIsNotAbsolute(let path):
      "The Turnrail router path must be absolute: \(path)"
    case .routerIsNotExecutable(let path):
      "The Turnrail router is not executable at \(path)."
    }
  }
}

public enum RouterPathResolver {
  public static let developmentEnvironmentKey = "CODEX_TURNRAIL_ROUTER_PATH"

  public static func resolve(
    isPackagedApp: Bool,
    executablesURL: URL?,
    environment: [String: String],
    fileManager: FileManager = .default
  ) throws -> URL {
    let routerURL: URL

    if isPackagedApp {
      guard let executablesURL else {
        throw RouterPathResolverError.packagedResourcesUnavailable
      }
      routerURL = executablesURL.appending(path: "CodexTurnrailRouter")
    } else {
      guard
        let path = environment[developmentEnvironmentKey]?.trimmingCharacters(
          in: .whitespacesAndNewlines
        ), !path.isEmpty
      else {
        throw RouterPathResolverError.developmentPathMissing
      }
      guard path.hasPrefix("/") else {
        throw RouterPathResolverError.pathIsNotAbsolute(path)
      }
      routerURL = URL(filePath: path)
    }

    guard fileManager.isExecutableFile(atPath: routerURL.path) else {
      throw RouterPathResolverError.routerIsNotExecutable(routerURL.path)
    }

    return routerURL
  }
}
