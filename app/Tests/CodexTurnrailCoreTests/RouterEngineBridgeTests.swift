import Darwin
import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterEngineBridgeTests {
  @Test(.timeLimit(.minutes(1)))
  func relaysRequestsAndResponsesWhileProtectingRoutingAndTrackingResumes() throws {
    let root = try RouterTestDirectory()
    let accounts = try FixtureAccounts(root: root.url)
    let runtime = try RouterRuntime(root: root.url, accounts: accounts) { _, _ in
      fatalError("This fixture never contacts a model service.")
    }
    defer { runtime.stop() }
    let desktopInput = Pipe()
    let desktopOutput = Pipe()
    var sockets: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
    let bridge = FileHandle(fileDescriptor: sockets[0], closeOnDealloc: true)
    let engine = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)
    let deadline = DispatchWorkItem {
      _ = shutdown(engine.fileDescriptor, SHUT_RDWR)
      try? desktopInput.fileHandleForWriting.close()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: deadline)
    defer {
      deadline.cancel()
      try? desktopInput.fileHandleForWriting.close()
      try? desktopInput.fileHandleForReading.close()
      try? desktopOutput.fileHandleForWriting.close()
      try? desktopOutput.fileHandleForReading.close()
      try? bridge.close()
      try? engine.close()
    }
    try send(
      ["id": "init", "method": "initialize", "params": [:]], to: desktopInput.fileHandleForWriting)
    let input = try RouterEngineInput(desktopInput.fileHandleForReading)
    let finished = DispatchSemaphore(value: 0)
    let result = BridgeTestResult()
    let rootURL = root.url
    DispatchQueue.global().async {
      defer {
        try? desktopOutput.fileHandleForWriting.close()
        finished.signal()
      }
      do {
        let status = try OfficialEngineRouter.relay(
          input: input, engineInput: bridge, engineOutput: bridge,
          desktopOutput: desktopOutput.fileHandleForWriting, home: rootURL,
          executable: rootURL.appending(path: "router"), engine: rootURL.appending(path: "engine"),
          appVersion: "fixture", runtime: runtime)
        result.complete(status: status, error: nil)
      } catch { result.complete(status: nil, error: error.localizedDescription) }
    }
    let engineReader = EngineLineReader(engine)
    let desktopReader = EngineLineReader(desktopOutput.fileHandleForReading)
    #expect(try read(engineReader)["id"] as? String == "init")
    try send(
      [
        "id": "blocked", "method": "config/value/write",
        "params": ["keyPath": "features.hooks", "value": false],
      ], to: desktopInput.fileHandleForWriting)
    try send(
      [
        "id": "load", "method": "thread/resume", "params": ["threadId": "thread"],
      ], to: desktopInput.fileHandleForWriting)
    let rejection = try read(desktopReader)
    #expect(rejection["id"] as? String == "blocked")
    #expect(try RouterJSON.map(rejection, "error")["code"] as? Int == -32602)
    #expect(try read(engineReader)["id"] as? String == "load")
    try send(
      [
        "id": "load", "result": ["thread": ["id": "thread", "cwd": root.url.path]],
      ], to: engine)
    #expect(try read(desktopReader)["id"] as? String == "load")
    try send(
      [
        "id": "resume", "method": "turn/start",
        "params": [
          "threadId": "thread", "turnTrigger": "resume_interrupted_task", "input": [Any](),
        ],
      ], to: desktopInput.fileHandleForWriting)
    #expect(try read(engineReader)["id"] as? String == "resume")
    try send(["id": "resume", "result": ["turn": ["id": "resumed"]]], to: engine)
    #expect(try read(desktopReader)["id"] as? String == "resume")
    try runtime.bindResumedTurn([
      "thread_id": "thread", "turn_id": "resumed", "turn_trigger": "resume_interrupted_task",
      "request_kind": "turn",
    ])
    #expect(try runtime.ledger.bound("thread/resumed") == accounts.first.account.id)
    try desktopInput.fileHandleForWriting.close()
    #expect(try engineReader.next() == nil)
    try #require(shutdown(engine.fileDescriptor, SHUT_WR) == 0)
    try #require(finished.wait(timeout: .now() + 5) == .success)
    #expect(result.status == 0)
    #expect(result.error == nil)
  }

  private func send(_ value: [String: Any], to handle: FileHandle) throws {
    try handle.write(contentsOf: RouterJSON.data(value) + Data([10]))
  }

  private func read(_ reader: EngineLineReader) throws -> [String: Any] {
    let raw = try reader.next()
    return try RouterJSON.object(#require(raw))
  }
}

private final class BridgeTestResult: @unchecked Sendable {
  private let lock = NSLock()
  private var value: (Int32?, String?) = (nil, nil)
  var status: Int32? { lock.withLock { value.0 } }
  var error: String? { lock.withLock { value.1 } }
  func complete(status: Int32?, error: String?) { lock.withLock { value = (status, error) } }
}
