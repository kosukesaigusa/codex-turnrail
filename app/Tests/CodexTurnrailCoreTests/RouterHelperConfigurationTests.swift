import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterHelperConfigurationTests {
  let router = URL(filePath: "/Applications/Turnrail.app/Contents/MacOS/CodexTurnrailRouter")
  let engine = URL(filePath: "/Applications/ChatGPT.app/Contents/Resources/codex")

  @Test
  func generatedPluginUsesOfficialCLIAndPreservesAllOtherFields() throws {
    let home = try RouterTestDirectory()
    let file = pluginFile(home.url)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let server: [String: Any] = [
      "command": "/official/node", "args": ["/official/cua-repl.mjs"], "enabled": true,
      "env_vars": ["EXISTING_ENV"],
      "env": [
        "CODEX_CLI_PATH": router.path, "CODEX_HOME": home.url.path,
        "NODE_REPL_FORCE_STRICT_AUTO_REVIEW": "1", "CUA_REPL_ENABLED_SURFACES": "browser",
      ],
      "tools": ["js": ["approval_mode": "approve"]],
    ]
    let original: [String: Any] = ["mcpServers": ["cua_repl": server], "description": "Fixture"]
    try RouterJSON.writePrivate(RouterJSON.data(original), to: file)
    try RouterHelperConfiguration.synchronizePlugin(home: home.url, router: router, engine: engine)
    var expectedServer = server
    var expectedEnvironment = try RouterJSON.map(server, "env")
    expectedEnvironment["CODEX_CLI_PATH"] = engine.path
    expectedServer["env"] = expectedEnvironment
    let expected: [String: Any] = [
      "mcpServers": ["cua_repl": expectedServer], "description": "Fixture",
    ]
    let prepared = try Data(contentsOf: file)
    #expect(try prepared == RouterJSON.data(expected))
    let modified = try file.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
    try RouterHelperConfiguration.synchronizePlugin(home: home.url, router: router, engine: engine)
    #expect(try Data(contentsOf: file) == prepared)
    #expect(
      try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        == modified)
  }

  @Test
  func absentOrExplicitOtherPluginCLIIsNotChanged() throws {
    let home = try RouterTestDirectory()
    let file = pluginFile(home.url)
    try RouterHelperConfiguration.synchronizePlugin(home: home.url, router: router, engine: engine)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    for environment in [["CODEX_CLI_PATH": "/custom/codex"], ["UNRELATED": "value"]] {
      let original = try RouterJSON.data(["mcpServers": ["cua_repl": ["env": environment]]])
      try RouterJSON.writePrivate(original, to: file)
      try RouterHelperConfiguration.synchronizePlugin(
        home: home.url, router: router, engine: engine)
      #expect(try Data(contentsOf: file) == original)
    }
  }

  @Test
  func generatedPluginSymlinksAreRejectedWithoutChangingTheirTarget() throws {
    let home = try RouterTestDirectory()
    let file = pluginFile(home.url)
    let target = home.url.appending(path: "unrelated.json")
    let data = try RouterJSON.data([
      "mcpServers": ["cua_repl": ["env": ["CODEX_CLI_PATH": router.path]]]
    ])
    try RouterJSON.writePrivate(data, to: target)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    #expect(throws: (any Error).self) {
      try RouterHelperConfiguration.synchronizePlugin(
        home: home.url, router: router, engine: engine)
    }
    #expect(try Data(contentsOf: target) == data)
  }

  private func pluginFile(_ home: URL) -> URL {
    home.appending(
      path: "plugins/cache/openai-bundled/unified-computer-use/"
        + CodexCompatibilityContract.supported.appVersion + "/.mcp.json")
  }

  @Test(arguments: ["thread/start", "thread/resume", "thread/fork"])
  func desktopHelperUsesOfficialCLIWithoutChangingSecurityConfiguration(method: String) throws {
    let environment: [String: Any] = [
      "CODEX_CLI_PATH": router.path, "CODEX_HOME": "/private/task-home",
      "NODE_REPL_FORCE_STRICT_AUTO_REVIEW": "1",
    ]
    let server: [String: Any] = ["command": "/official/node_repl", "env": environment]
    let config: [String: Any] = [
      "mcp_servers.cua_repl": server, "mcp_servers.node_repl": server,
      "browser_use": ["default_origin_policy": ["access": "deny"]],
      "approval_policy": "on-request",
    ]
    let message: [String: Any] = [
      "id": "request", "method": method,
      "params": ["config": config, "cwd": "/private/task-home"],
    ]
    var expectedEnvironment = environment
    expectedEnvironment["CODEX_CLI_PATH"] = engine.path
    var expectedServer = server
    expectedServer["env"] = expectedEnvironment
    var expectedConfig = config
    expectedConfig["mcp_servers.cua_repl"] = expectedServer
    expectedConfig["mcp_servers.node_repl"] = expectedServer
    var expected = message
    expected["params"] = ["config": expectedConfig, "cwd": "/private/task-home"]
    let actual = RouterHelperConfiguration.prepare(message, router: router, engine: engine)
    #expect(try RouterJSON.data(actual) == RouterJSON.data(expected))
  }

  @Test
  func nestedAndDottedHelperOverridesResolveTheSameOfficialCLI() throws {
    let variants: [([String: Any], [String: Any])] = [
      (
        ["mcp_servers": ["cua_repl": ["env": ["CODEX_CLI_PATH": router.path]]]],
        ["mcp_servers": ["cua_repl": ["env": ["CODEX_CLI_PATH": engine.path]]]]
      ),
      (
        ["mcp_servers.cua_repl.env.CODEX_CLI_PATH": router.path],
        ["mcp_servers.cua_repl.env.CODEX_CLI_PATH": engine.path]
      ),
    ]
    for (config, expected) in variants {
      let actual = RouterHelperConfiguration.prepare(
        ["method": "thread/resume", "params": ["config": config]], router: router, engine: engine)
      let params = try RouterJSON.map(actual, "params")
      #expect(try RouterJSON.data(params["config"]!) == RouterJSON.data(expected))
    }
  }

  @Test
  func explicitOtherCLIsAndUnrelatedRequestsRemainUnchanged() throws {
    for config: [String: Any] in [
      ["mcp_servers.other": ["env": ["CODEX_CLI_PATH": "/custom/codex"]]],
      ["shell_environment_policy": ["set": ["CODEX_CLI_PATH": router.path]]],
    ] {
      let message: [String: Any] = ["method": "thread/start", "params": ["config": config]]
      let prepared = RouterHelperConfiguration.prepare(message, router: router, engine: engine)
      #expect(try RouterJSON.data(prepared) == RouterJSON.data(message))
    }
    let response: [String: Any] = ["id": "tool", "result": ["CODEX_CLI_PATH": router.path]]
    #expect(
      try RouterJSON.data(
        RouterHelperConfiguration.prepare(response, router: router, engine: engine))
        == RouterJSON.data(response))
  }
}
