import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterPathResolverTests {
  @Test
  func packagedAppUsesItsRuntimePackage() throws {
    let resources = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: resources) }
    let executable = resources.appending(path: "CodexTurnrailRouter")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let resolved = try RouterPathResolver.resolve(
      isPackagedApp: true,
      executablesURL: resources,
      environment: [RouterPathResolver.developmentEnvironmentKey: "/unrelated/codex"]
    )

    #expect(resolved == executable)
    try FileManager.default.removeItem(at: executable)
    #expect(throws: RouterPathResolverError.routerIsNotExecutable(executable.path)) {
      try RouterPathResolver.resolve(
        isPackagedApp: true, executablesURL: resources, environment: [:]
      )
    }
  }

  @Test
  func developmentRequiresAnExplicitEnginePath() {
    #expect(throws: RouterPathResolverError.developmentPathMissing) {
      try RouterPathResolver.resolve(
        isPackagedApp: false,
        executablesURL: nil,
        environment: [:]
      )
    }
  }

  @Test
  func developmentRejectsARelativeEnginePath() {
    #expect(throws: RouterPathResolverError.pathIsNotAbsolute("bin/codex")) {
      try RouterPathResolver.resolve(
        isPackagedApp: false,
        executablesURL: nil,
        environment: [
          RouterPathResolver.developmentEnvironmentKey: "bin/codex"
        ]
      )
    }
  }
}
