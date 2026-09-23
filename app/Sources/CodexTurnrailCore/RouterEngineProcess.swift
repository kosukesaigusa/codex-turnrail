import Darwin
import Foundation

/// Owns one process group, so shutdown cannot terminate another ChatGPT instance.
final class RouterEngineProcess: @unchecked Sendable {
  let pid: pid_t
  let input: FileHandle
  let output: FileHandle
  private let lock = NSLock()
  private let waitLock = NSLock()
  private var reaped = false
  private var exitStatus: Int32?

  init(
    executable: URL, arguments: [String], environment: [String: String],
    error: FileHandle = .standardError
  ) throws {
    var toEngine: [Int32] = [0, 0]
    var fromEngine: [Int32] = [0, 0]
    guard pipe(&toEngine) == 0 else {
      throw RouterFailure("Could not create the Engine input pipe.")
    }
    guard pipe(&fromEngine) == 0 else {
      close(toEngine[0])
      close(toEngine[1])
      throw RouterFailure("Could not create the Engine output pipe.")
    }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }
    posix_spawn_file_actions_adddup2(&actions, toEngine[0], STDIN_FILENO)
    posix_spawn_file_actions_adddup2(&actions, fromEngine[1], STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, error.fileDescriptor, STDERR_FILENO)
    posix_spawnattr_setpgroup(&attributes, 0)
    var signals = sigset_t()
    sigemptyset(&signals)
    for value in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&signals, value) }
    posix_spawnattr_setsigdefault(&attributes, &signals)
    var mask = sigset_t()
    sigemptyset(&mask)
    posix_spawnattr_setsigmask(&attributes, &mask)
    posix_spawnattr_setflags(
      &attributes,
      Int16(
        POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
          | POSIX_SPAWN_CLOEXEC_DEFAULT))
    let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
    let envp = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
    defer {
      for value in argv { free(value) }
      for value in envp { free(value) }
    }
    var child: pid_t = 0
    let status = argv.withUnsafeBufferPointer { argv in
      envp.withUnsafeBufferPointer { envp in
        posix_spawn(
          &child, executable.path, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
      }
    }
    close(toEngine[0])
    close(fromEngine[1])
    guard status == 0 else {
      close(toEngine[1])
      close(fromEngine[0])
      throw RouterFailure("Could not start the official Engine (\(status)).")
    }
    pid = child
    input = FileHandle(fileDescriptor: toEngine[1], closeOnDealloc: true)
    output = FileHandle(fileDescriptor: fromEngine[0], closeOnDealloc: true)
  }

  func terminate() { lock.withLock { if !reaped { kill(-pid, SIGTERM) } } }

  func forceTerminate() { lock.withLock { if !reaped { kill(-pid, SIGKILL) } } }

  func wait() -> Int32 {
    waitLock.withLock {
      if let saved = lock.withLock({ exitStatus }) { return saved }
      var information = siginfo_t()
      var result: Int32
      repeat {
        result = waitid(P_PID, id_t(pid), &information, WEXITED | WNOWAIT)
      } while result < 0 && errno == EINTR
      if result == 0 {
        // The unreaped leader reserves the group ID while its helpers are stopped.
        kill(-pid, SIGKILL)
      }
      var status: Int32 = 0
      var waited: pid_t
      repeat { waited = waitpid(pid, &status, 0) } while waited < 0 && errno == EINTR
      let code: Int32 = waited == pid && status == 0 ? 0 : 1
      lock.withLock {
        reaped = true
        exitStatus = code
      }
      return code
    }
  }

  func stop() {
    terminate()
    // The group ID remains reserved until waitpid reaps its leader.
    let killer = DispatchWorkItem {
      self.lock.withLock { if !self.reaped { kill(-self.pid, SIGKILL) } }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
    _ = wait()
    killer.cancel()
  }
}

final class RouterEngineObserver: @unchecked Sendable {
  private let lock = NSLock()
  private var titles = Set<String>()

  static func isAppServer(_ arguments: [String]) throws -> Bool {
    if [["--version"], ["-V"], ["--help"], ["-h"]].contains(arguments) { return false }
    var index = 0
    while index < arguments.count {
      let value = arguments[index]
      if ["-c", "--config", "--enable", "--disable"].contains(value) {
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else {
          throw RouterFailure("Missing official Engine option value.")
        }
        index += 2
      } else if ["--config=", "--enable=", "--disable="].contains(where: { value.hasPrefix($0) }) {
        guard !value.hasSuffix("=") else {
          throw RouterFailure("Missing official Engine option value.")
        }
        index += 1
      } else if value == "--strict-config" {
        index += 1
      } else {
        guard value == "app-server" else {
          throw RouterFailure("Turnrail requires the official app-server entry point.")
        }
        for offset in arguments.indices where offset > index {
          if arguments[offset] == "--listen" {
            guard offset + 1 < arguments.count, arguments[offset + 1] == "stdio://" else {
              throw RouterFailure("Turnrail requires stdio transport.")
            }
          } else if arguments[offset].hasPrefix("--listen="),
            arguments[offset] != "--listen=stdio://"
          {
            throw RouterFailure("Turnrail requires stdio transport.")
          }
        }
        return true
      }
    }
    throw RouterFailure("Missing official Engine entry point.")
  }

  func request(_ message: [String: Any]) throws {
    guard let method = message["method"] as? String else { return }
    if let params = message["params"] as? [String: Any] {
      for key in ["modelProvider", "model_provider"] {
        if let provider = params[key] as? String, provider != "openai" {
          throw RouterFailure("Turnrail routing requires the OpenAI model provider.")
        }
      }
      if let config = params["config"] as? [String: Any] {
        for (key, value) in Self.leaves(config) where Self.routingSetting(key) {
          // The official title helper deliberately disables normal prompt hooks.
          if key == "features.hooks", value as? Bool == false,
            ["thread/start", "thread/fork"].contains(method),
            params["threadSource"] as? String == "thread_title"
          {
            continue
          }
          throw RouterFailure("A task cannot override Turnrail routing configuration.")
        }
      }
      if method == "config/value/write", Self.changesRouting(params) {
        throw RouterFailure("Quit Turnrail mode before changing routing configuration.")
      }
      if method == "config/batchWrite", let edits = params["edits"] as? [[String: Any]],
        edits.contains(where: Self.changesRouting)
      {
        throw RouterFailure("Quit Turnrail mode before changing routing configuration.")
      }
      if ["thread/start", "thread/fork"].contains(method),
        params["threadSource"] as? String == "thread_title"
      {
        let id = try Self.id(message)
        try lock.withLock {
          guard titles.insert(id).inserted else {
            throw RouterFailure("Duplicate pending title task request.")
          }
        }
      }
    }
  }

  private static func changesRouting(_ edit: [String: Any]) -> Bool {
    guard let path = edit["keyPath"] as? String else { return true }
    guard let segments = configurationPath(path) else { return true }
    let normalized = segments.joined(separator: ".")
    if routingSetting(normalized) { return true }
    // Replacing a parent table also changes its protected descendants.
    if normalized == "features", edit["mergeStrategy"] as? String == "replace" { return true }
    if let value = edit["value"] as? [String: Any] {
      return leaves(value, prefix: normalized).contains { routingSetting($0.0) }
    }
    return false
  }

  // Match the official config API's quoted segments and escaped punctuation.
  // Invalid paths must not bypass the routing guard before the Engine validates them.
  private static func configurationPath(_ path: String) -> [String]? {
    var segments: [String] = []
    var segment = ""
    var quoted = false
    var escaped = false
    for character in path {
      if escaped {
        segment.append(character)
        escaped = false
      } else if character == "\\", quoted {
        escaped = true
      } else if character == "\"", segment.isEmpty && !quoted {
        quoted = true
      } else if character == "\"", quoted {
        quoted = false
      } else if character == ".", !quoted {
        guard !segment.isEmpty else { return nil }
        segments.append(segment)
        segment = ""
      } else if character == "\"" {
        return nil
      } else {
        segment.append(character)
      }
    }
    guard !quoted, !escaped, !segment.isEmpty else { return nil }
    return segments + [segment]
  }

  private static func routingSetting(_ key: String) -> Bool {
    [
      "openai_base_url", "model_provider", "model_providers", "model_catalog_json", "hooks",
      "features.hooks", "features.remote_models",
    ].contains { key == $0 || key.hasPrefix($0 + ".") }
  }

  private static func leaves(_ value: [String: Any], prefix: String = "") -> [(String, Any)] {
    value.flatMap { key, item in
      let path = prefix.isEmpty ? key : prefix + "." + key
      if let nested = item as? [String: Any], !nested.isEmpty {
        return leaves(nested, prefix: path)
      }
      return [(path, item)]
    }
  }

  func response(_ message: [String: Any], register: ([String: Any]) throws -> Void) throws {
    guard message["method"] == nil, message["id"] != nil else { return }
    let id = try Self.id(message)
    guard lock.withLock({ titles.remove(id) != nil }), message["error"] == nil else { return }
    try register(RouterJSON.map(RouterJSON.map(message, "result"), "thread"))
  }

  private static func id(_ message: [String: Any]) throws -> String {
    if let id = message["id"] as? String { return "s:" + id }
    if let id = message["id"] as? Int { return "n:\(id)" }
    throw RouterFailure("Invalid Engine protocol request ID.")
  }
}
