import Darwin
import Foundation

/// Desktop MCP helpers inspect policy with the official CLI, independently of routing.
enum RouterHelperConfiguration {
  static let loadingMethods: Set<String> = [
    "thread/start", "thread/resume", "thread/fork", "config/mcpServer/reload",
    "mcpServerStatus/list",
  ]

  /// The desktop generates this plugin separately from per-task MCP overrides.
  ///
  /// Correct only our own CLI override before the official Engine loads the plugin.
  /// The plugin's transport, surfaces, approval policy, and other environment stay intact.
  static func synchronizePlugin(home: URL, router: URL, engine: URL) throws {
    let file = home.appending(
      path: "plugins/cache/openai-bundled/unified-computer-use/"
        + CodexCompatibilityContract.supported.appVersion + "/.mcp.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return }
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == geteuid(),
      let size = attributes[.size] as? NSNumber, size.intValue <= 1024 * 1024,
      file.resolvingSymlinksInPath().path.hasPrefix(home.resolvingSymlinksInPath().path + "/")
    else { throw RouterFailure("The generated browser plugin configuration is not an owned file.") }
    let original = try Data(contentsOf: file)
    var document = try RouterJSON.object(original)
    var servers = try RouterJSON.map(document, "mcpServers")
    var server = try RouterJSON.map(servers, "cua_repl")
    guard var environment = server["env"] as? [String: Any],
      environment["CODEX_CLI_PATH"] as? String == router.path
    else { return }
    environment["CODEX_CLI_PATH"] = engine.path
    server["env"] = environment
    servers["cua_repl"] = server
    document["mcpServers"] = servers
    guard try Data(contentsOf: file) == original else {
      throw RouterFailure("The desktop changed browser configuration during preparation. Retry.")
    }
    try RouterJSON.writePrivate(RouterJSON.data(document), to: file)
  }

  static func prepare(_ message: [String: Any], router: URL, engine: URL) -> [String: Any] {
    guard let method = message["method"] as? String,
      ["thread/start", "thread/resume", "thread/fork"].contains(method),
      var params = message["params"] as? [String: Any],
      let config = params["config"] as? [String: Any]
    else { return message }
    params["config"] = rewrite(config, prefix: "", router: router.path, engine: engine.path)
    var prepared = message
    prepared["params"] = params
    return prepared
  }

  private static func rewrite(
    _ config: [String: Any], prefix: String, router: String, engine: String
  ) -> [String: Any] {
    var result = config
    for (key, value) in config {
      let path = prefix.isEmpty ? key : prefix + "." + key
      if let nested = value as? [String: Any] {
        result[key] = rewrite(nested, prefix: path, router: router, engine: engine)
      } else if path.hasPrefix("mcp_servers."), path.hasSuffix(".env.CODEX_CLI_PATH"),
        value as? String == router
      {
        // The desktop app repeats its CLI override in per-task MCP environments.
        // These helpers receive no routing context and must not start another router.
        result[key] = engine
      }
    }
    return result
  }
}
