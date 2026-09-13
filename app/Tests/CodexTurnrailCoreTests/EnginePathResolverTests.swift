import Foundation
import Testing

@testable import CodexTurnrailCore

struct EnginePathResolverTests {
  @Test
  func packagedAppUsesItsRuntimePackage() throws {
    let resources = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: resources) }
    let executable = resources.appending(path: "engine/bin/codex")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let resolved = try EnginePathResolver.resolve(
      isPackagedApp: true,
      resourcesURL: resources,
      environment: [EnginePathResolver.developmentEnvironmentKey: "/unrelated/codex"]
    )

    #expect(resolved == executable)
    try FileManager.default.removeItem(at: executable)
    #expect(throws: EnginePathResolverError.engineIsNotExecutable(executable.path)) {
      try EnginePathResolver.resolve(
        isPackagedApp: true, resourcesURL: resources, environment: [:]
      )
    }
  }

  @Test
  func developmentRequiresAnExplicitEnginePath() {
    #expect(throws: EnginePathResolverError.developmentPathMissing) {
      try EnginePathResolver.resolve(
        isPackagedApp: false,
        resourcesURL: nil,
        environment: [:]
      )
    }
  }

  @Test
  func developmentRejectsARelativeEnginePath() {
    #expect(throws: EnginePathResolverError.pathIsNotAbsolute("bin/codex")) {
      try EnginePathResolver.resolve(
        isPackagedApp: false,
        resourcesURL: nil,
        environment: [
          EnginePathResolver.developmentEnvironmentKey: "bin/codex"
        ]
      )
    }
  }
}
