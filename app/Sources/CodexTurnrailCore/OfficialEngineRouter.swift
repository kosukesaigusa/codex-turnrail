import Darwin
import Foundation

public enum OfficialEngineRouter {
  public static func run(arguments: [String], environment: [String: String], executable: URL) throws
    -> Int32
  {
    if arguments.first == "hook" {
      guard arguments.count == 2 else {
        throw RouterFailure("The hook requires its runtime session directory.")
      }
      return hook(session: URL(filePath: arguments[1]))
    }
    guard let appPath = environment["CODEX_TURNRAIL_APP"], appPath.hasPrefix("/") else {
      throw RouterFailure("CODEX_TURNRAIL_APP must name the official ChatGPT installation.")
    }
    let engine = URL(filePath: appPath).appending(path: "Contents/Resources/codex")
    try OfficialEngineInstallation.verify(app: URL(filePath: appPath))
    if try !RouterEngineObserver.isAppServer(arguments) {
      let result = try CommandExecutor.live.execute(
        engine, arguments: arguments, environment: environment)
      try FileHandle.standardOutput.write(contentsOf: Data(result.standardOutput.utf8))
      try FileHandle.standardError.write(contentsOf: Data(result.standardError.utf8))
      return result.exitCode
    }
    if try RouterHelperProcess.isComputerUseService(processID: getppid()) {
      try RouterHelperProcess.replace(
        engine: engine, arguments: arguments, environment: environment)
    }
    guard let rootPath = environment["CODEX_TURNRAIL_ROOT"], rootPath.hasPrefix("/") else {
      throw RouterFailure("CODEX_TURNRAIL_ROOT must name the account registry.")
    }
    // This is the official CLI's documented default home, not a routing fallback.
    let home: URL
    if let configured = environment["CODEX_HOME"] {
      home = try RouterDirectory.canonical(configured)
    } else {
      home = try RouterDirectory.canonical(
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex").path)
    }
    try RouterHelperConfiguration.synchronizePlugin(home: home, router: executable, engine: engine)
    let runtime = try RouterRuntime(root: URL(filePath: rootPath), engine: engine)
    defer { runtime.stop() }
    runtime.start()
    let overrides = try runtime.configuration(engine: engine, home: home, executable: executable)
    let childEnvironment = RouterHelperProcess.environment(environment, engine: engine)
    let child = try RouterEngineProcess(
      executable: engine, arguments: arguments + overrides.flatMap { ["-c", $0] },
      environment: childEnvironment)
    let observer = RouterEngineObserver()
    signal(SIGPIPE, SIG_IGN)
    var signals: [DispatchSourceSignal] = []
    for number in [SIGTERM, SIGINT, SIGHUP] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler {
        child.terminate()
        runtime.stop()
      }
      source.resume()
      signals.append(source)
    }
    defer {
      for source in signals { source.cancel() }
      child.stop()
    }
    let outputLock = NSLock()
    let worker = DispatchGroup()
    worker.enter()
    DispatchQueue(label: "Turnrail.engine.input").async {
      defer {
        try? child.input.close()
        worker.leave()
      }
      do {
        let reader = EngineLineReader(FileHandle.standardInput)
        while let raw = try reader.next() {
          let message = try RouterJSON.object(raw)
          do {
            if let method = message["method"] as? String,
              RouterHelperConfiguration.loadingMethods.contains(method)
            {
              try RouterHelperConfiguration.synchronizePlugin(
                home: home, router: executable, engine: engine)
            }
            try observer.request(message)
          } catch {
            guard let id = message["id"] else { throw error }
            var reply = try RouterJSON.data([
              "id": id, "error": ["code": -32602, "message": error.localizedDescription],
            ])
            reply.append(0x0A)
            try outputLock.withLock { try FileHandle.standardOutput.write(contentsOf: reply) }
            continue
          }
          let prepared = RouterHelperConfiguration.prepare(
            message, router: executable, engine: engine)
          var line = try RouterJSON.data(prepared)
          line.append(0x0A)
          try child.input.write(contentsOf: line)
        }
      } catch { child.terminate() }
    }
    let reader = EngineLineReader(child.output)
    while let raw = try reader.next() {
      let message = try RouterJSON.object(raw)
      do { try observer.response(message, register: runtime.registerTitle) } catch {
        // A title-routing failure belongs to that request, not to every active task.
        guard message["method"] == nil, let id = message["id"] else { throw error }
        var reply = try RouterJSON.data([
          "id": id, "error": ["code": -32603, "message": error.localizedDescription],
        ])
        reply.append(0x0A)
        try outputLock.withLock { try FileHandle.standardOutput.write(contentsOf: reply) }
        continue
      }
      var line = raw
      line.append(0x0A)
      try outputLock.withLock { try FileHandle.standardOutput.write(contentsOf: line) }
    }
    return child.wait()
  }

  private static func hook(session: URL) -> Int32 {
    do {
      let endpoint = try RouterJSON.object(
        Data(contentsOf: session.appending(path: "endpoint.json")))
      guard let port = endpoint["port"] as? Int, (1...65535).contains(port) else {
        throw RouterFailure("Invalid hook endpoint.")
      }
      let secret = try RouterJSON.text(endpoint, "secret")
      guard secret.allSatisfy({ $0.isHexDigit || $0 == "-" }) else {
        throw RouterFailure("Invalid hook endpoint identity.")
      }
      var inputData = Data()
      while let chunk = try FileHandle.standardInput.read(upToCount: 65536), !chunk.isEmpty {
        guard inputData.count + chunk.count <= 64 * 1024 * 1024 else {
          throw RouterFailure("The hook input exceeds the supported size.")
        }
        inputData.append(chunk)
      }
      let input = try RouterJSON.object(inputData)
      var event: [String: Any] = [:]
      for name in ["session_id", "turn_id", "cwd", "hook_event_name"] {
        event[name] = try RouterJSON.text(input, name)
      }
      if input["agent_id"] != nil && !(input["agent_id"] is NSNull) {
        event["agent_id"] = try RouterJSON.text(input, "agent_id")
      }
      let fd = socket(AF_INET, SOCK_STREAM, 0)
      guard fd >= 0 else { throw RouterFailure("Could not open the hook connection.") }
      let connection = RouterSocket(fd)
      defer { connection.close() }
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = UInt16(port).bigEndian
      address.sin_addr.s_addr = inet_addr("127.0.0.1")
      let status = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      guard status == 0 else { throw RouterFailure("The Turnrail router is not running.") }
      let body = try RouterJSON.data(event)
      var request = Data(
        "POST /\(secret)/hook HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
          .utf8)
      request.append(body)
      try connection.write(request)
      var head = Data()
      while !head.suffix(4).elementsEqual([13, 10, 13, 10]) {
        head.append(try connection.read(1))
        guard head.count <= 8192 else { throw RouterFailure("Invalid hook reply headers.") }
      }
      let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
      guard lines.first?.hasPrefix("HTTP/1.1 200 ") == true,
        let sizeLine = lines.first(where: { $0.lowercased().hasPrefix("content-length: ") }),
        let size = Int(sizeLine.dropFirst(16)), (1...16384).contains(size)
      else { throw RouterFailure("The router rejected the hook.") }
      let response = try connection.read(size)
      guard try RouterJSON.object(response)["continue"] is Bool else {
        throw RouterFailure("Invalid hook decision.")
      }
      try FileHandle.standardOutput.write(contentsOf: response + Data([0x0A]))
    } catch {
      let reply = ["continue": false, "stopReason": error.localizedDescription] as [String: Any]
      if let data = try? RouterJSON.data(reply) {
        try? FileHandle.standardOutput.write(contentsOf: data + Data([0x0A]))
      }
    }
    return 0
  }
}

public enum OfficialEngineInstallation {
  public static func verify(app: URL) throws {
    let engine = app.appending(path: "Contents/Resources/codex")
    for binary in [app, engine, app.appending(path: "Contents/Resources/codex-code-mode-host")] {
      var requirement = "anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\""
      if binary == app { requirement += " and identifier \"com.openai.codex\"" }
      let verification = try CommandExecutor.live.execute(
        URL(filePath: "/usr/bin/codesign"),
        arguments: ["--verify", "--deep", "--strict", "-R=" + requirement, binary.path],
        environment: ProcessInfo.processInfo.environment)
      guard verification.exitCode == 0 else {
        throw RouterFailure("ChatGPT and its Engine must have valid OpenAI signatures.")
      }
    }
    // Do not execute --version until the executable's origin has been verified.
    let report = try CompatibilityProbe().probe(appURL: app, engineURL: engine)
    guard report.isCompatible else {
      throw RouterFailure(report.mismatches.joined(separator: "\n"))
    }
  }
}
