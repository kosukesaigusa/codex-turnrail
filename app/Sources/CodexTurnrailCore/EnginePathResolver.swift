import Foundation

public enum EnginePathResolverError: LocalizedError, Equatable {
  case packagedResourcesUnavailable
  case developmentPathMissing
  case pathIsNotAbsolute(String)
  case engineIsNotExecutable(String)

  public var errorDescription: String? {
    switch self {
    case .packagedResourcesUnavailable:
      "The packaged app does not expose a Resources directory."
    case .developmentPathMissing:
      "Set CODEX_TURNRAIL_ENGINE_PATH to run the development app."
    case .pathIsNotAbsolute(let path):
      "The Turnrail Engine path must be absolute: \(path)"
    case .engineIsNotExecutable(let path):
      "The Turnrail Engine is not executable at \(path)."
    }
  }
}

public enum EnginePathResolver {
  public static let developmentEnvironmentKey = "CODEX_TURNRAIL_ENGINE_PATH"

  public static func resolve(
    isPackagedApp: Bool,
    resourcesURL: URL?,
    environment: [String: String],
    fileManager: FileManager = .default
  ) throws -> URL {
    let engineURL: URL

    if isPackagedApp {
      guard let resourcesURL else {
        throw EnginePathResolverError.packagedResourcesUnavailable
      }
      engineURL = resourcesURL.appending(path: "engine/bin/codex")
    } else {
      guard
        let path = environment[developmentEnvironmentKey]?.trimmingCharacters(
          in: .whitespacesAndNewlines
        ), !path.isEmpty
      else {
        throw EnginePathResolverError.developmentPathMissing
      }
      guard path.hasPrefix("/") else {
        throw EnginePathResolverError.pathIsNotAbsolute(path)
      }
      engineURL = URL(filePath: path)
    }

    guard fileManager.isExecutableFile(atPath: engineURL.path) else {
      throw EnginePathResolverError.engineIsNotExecutable(engineURL.path)
    }

    return engineURL
  }
}
