import Darwin
import Foundation

/// Keep the official Engine in the desktop's direct child process.
///
/// The separate bridge owns routing and relays the app-server protocol. This leaves the
/// Engine and its native helpers in the ancestry expected by the desktop's peer verifier.
enum RouterEngineBridge {
  private static let engineDescriptor: Int32 = 10
  private static let bootstrapDescriptor: Int32 = 11

  static func replaceWithEngine(
    engine: URL, arguments: [String], environment: [String: String], executable: URL
  ) throws -> Int32 {
    guard [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO].allSatisfy({ fcntl($0, F_GETFD) >= 0 })
    else {
      throw RouterFailure("The Engine bridge requires open standard descriptors.")
    }
    var connection: [Int32] = [-1, -1]
    var bootstrap: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &connection) == 0 else {
      throw RouterFailure("Could not create the Engine bridge connection.")
    }
    defer {
      for fd in connection where fd >= 0 { close(fd) }
      for fd in bootstrap where fd >= 0 { close(fd) }
    }
    guard pipe(&bootstrap) == 0 else {
      throw RouterFailure("Could not create the Engine bridge bootstrap pipe.")
    }
    var engineSource = fcntl(connection[1], F_DUPFD_CLOEXEC, 12)
    guard engineSource >= 0 else { throw RouterFailure("Could not prepare the Engine bridge.") }
    defer { if engineSource >= 0 { close(engineSource) } }
    var bootstrapSource = fcntl(bootstrap[1], F_DUPFD_CLOEXEC, 12)
    guard bootstrapSource >= 0 else { throw RouterFailure("Could not prepare the Engine bridge.") }
    defer { if bootstrapSource >= 0 { close(bootstrapSource) } }

    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
      throw RouterFailure("Could not prepare the Engine bridge process.")
    }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawnattr_init(&attributes) == 0 else {
      throw RouterFailure("Could not prepare the Engine bridge process.")
    }
    defer { posix_spawnattr_destroy(&attributes) }
    for (source, target) in [
      (STDIN_FILENO, STDIN_FILENO), (STDOUT_FILENO, STDOUT_FILENO),
      (STDERR_FILENO, STDERR_FILENO), (engineSource, engineDescriptor),
      (bootstrapSource, bootstrapDescriptor),
    ] {
      guard posix_spawn_file_actions_adddup2(&actions, source, target) == 0 else {
        throw RouterFailure("Could not prepare the Engine bridge descriptors.")
      }
    }
    var signals = sigset_t()
    sigemptyset(&signals)
    for number in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&signals, number) }
    var mask = sigset_t()
    sigemptyset(&mask)
    guard posix_spawnattr_setsigdefault(&attributes, &signals) == 0,
      posix_spawnattr_setsigmask(&attributes, &mask) == 0,
      posix_spawnattr_setflags(
        &attributes,
        Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
    else { throw RouterFailure("Could not prepare the Engine bridge signals.") }
    let bridgeArguments: [String] = [executable.path, "router-bridge"]
    let argv = bridgeArguments.map { strdup($0) } + [nil]
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
    guard status == 0 else {
      throw RouterFailure("Could not start the Engine bridge (\(status)).")
    }
    close(connection[1])
    connection[1] = -1
    close(bootstrap[1])
    bootstrap[1] = -1
    // These duplicates are only needed during posix_spawn. Retaining either prevents EOF.
    close(engineSource)
    engineSource = -1
    close(bootstrapSource)
    bootstrapSource = -1
    let bootstrapInput = FileHandle(fileDescriptor: bootstrap[0], closeOnDealloc: false)
    guard let raw = try EngineLineReader(bootstrapInput).next() else {
      throw RouterFailure("The Engine bridge exited during startup.")
    }
    let reply = try RouterJSON.object(raw)
    if let message = reply["error"] as? String { throw RouterFailure(message) }
    if reply["exit"] as? Bool == true { return 0 }
    guard let overrides = reply["overrides"] as? [String] else {
      throw RouterFailure("The Engine bridge returned an invalid startup response.")
    }
    guard dup2(connection[0], STDIN_FILENO) >= 0, dup2(connection[0], STDOUT_FILENO) >= 0 else {
      throw RouterFailure("Could not connect the official Engine to its bridge.")
    }
    close(connection[0])
    connection[0] = -1
    close(bootstrap[0])
    bootstrap[0] = -1
    try RouterHelperProcess.replace(
      engine: engine, arguments: arguments + overrides.flatMap { ["-c", $0] },
      environment: environment)
  }

  static func run(environment: [String: String], executable: URL) throws -> Int32 {
    guard fcntl(engineDescriptor, F_GETFD) >= 0, fcntl(bootstrapDescriptor, F_GETFD) >= 0 else {
      throw RouterFailure("The Engine bridge requires its private descriptors.")
    }
    signal(SIGPIPE, SIG_IGN)
    let engine = FileHandle(fileDescriptor: engineDescriptor, closeOnDealloc: true)
    let bootstrap = FileHandle(fileDescriptor: bootstrapDescriptor, closeOnDealloc: true)
    let parent = getppid()
    guard parent > 1 else { throw RouterFailure("The Engine bridge has no parent.") }
    let lifetime = RouterBridgeLifetime()
    let stop: @Sendable () -> Void = {
      _ = shutdown(engineDescriptor, SHUT_RDWR)
      // Desktop input can block before the relay starts.
      if !lifetime.isReady { _exit(1) }
    }
    let monitor = DispatchSource.makeProcessSource(
      identifier: parent, eventMask: .exit, queue: .global())
    monitor.setEventHandler(handler: stop)
    monitor.resume()
    var signals: [DispatchSourceSignal] = []
    for number in [SIGTERM, SIGINT, SIGHUP] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler(handler: stop)
      source.resume()
      signals.append(source)
    }
    defer {
      monitor.cancel()
      for source in signals { source.cancel() }
    }
    do {
      let input = try RouterEngineInput(.standardInput)
      guard input.hasInitialization else {
        try bootstrap.write(contentsOf: RouterJSON.data(["exit": true]) + Data([10]))
        return 0
      }
      return try OfficialEngineRouter.bridge(
        input: input, engineInput: engine, engineOutput: engine,
        environment: environment, executable: executable, bootstrap: bootstrap,
        ready: { lifetime.markReady() })
    } catch {
      try? bootstrap.write(
        contentsOf: RouterJSON.data(["error": error.localizedDescription]) + Data([10]))
      throw error
    }
  }
}

private final class RouterBridgeLifetime: @unchecked Sendable {
  private let lock = NSLock()
  private var ready = false
  var isReady: Bool { lock.withLock { ready } }
  func markReady() { lock.withLock { ready = true } }
}
