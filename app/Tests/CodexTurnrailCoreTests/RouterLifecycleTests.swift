import Darwin
import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterLifecycleTests {
  @Test
  func protocolReaderPreservesBufferedLinesAndRejectsPartialEOF() throws {
    let root = try RouterTestDirectory()
    let file = root.url.appending(path: "protocol")
    let long = String(repeating: "x", count: 100000)
    try Data(("first\n" + long + "\nlast\npartial").utf8).write(to: file)
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    let reader = EngineLineReader(handle)
    #expect(try reader.next() == Data("first".utf8))
    #expect(try reader.next() == Data(long.utf8))
    #expect(try reader.next() == Data("last".utf8))
    #expect(throws: (any Error).self) { try reader.next() }
  }

  @Test(arguments: [false, true])
  func stoppingListenerReleasesItsAcceptWorker(afterConnection: Bool) throws {
    var listener: RouterListener? = try RouterListener()
    defer { listener?.stop() }
    weak var retained = listener
    let accepted = DispatchSemaphore(value: 0)
    listener?.start {
      $0.close()
      accepted.signal()
    }
    if afterConnection {
      let client = try listenerClient(port: #require(listener?.port))
      defer { client.close() }
      try #require(accepted.wait(timeout: .now() + 5) == .success)
    }
    listener?.stop()
    listener = nil
    for _ in 0..<100 where retained != nil { Thread.sleep(forTimeInterval: 0.01) }
    #expect(retained == nil)
  }

  @Test(arguments: [false, true])
  func releasingAnUnstartedListenerClosesItsPort(stopped: Bool) throws {
    var listener: RouterListener? = try RouterListener()
    weak var retained = listener
    let port = try #require(listener?.port)
    if stopped { listener?.stop() }
    listener = nil
    #expect(retained == nil)
    for _ in 0..<100 {
      do {
        let client = try listenerClient(port: port)
        client.close()
      } catch ListenerClientFailure.refused {
        return
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    Issue.record("The released listener's port remained open.")
  }

  @Test
  func stoppingListenerUnblocksActiveConnections() throws {
    let listener = try RouterListener()
    defer { listener.stop() }
    let waiting = DispatchSemaphore(value: 0)
    let received = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    listener.start { socket in
      defer { finished.signal() }
      let flags = fcntl(socket.descriptor, F_GETFL)
      #expect(flags >= 0 && flags & O_NONBLOCK == 0)
      waiting.signal()
      do {
        #expect(try socket.read(1) == Data([42]))
        received.signal()
        #expect(throws: RouterFailure.self) { try socket.read(1) }
      } catch {
        Issue.record("The accepted connection could not receive its fixture byte.")
      }
    }
    let client = try listenerClient(port: listener.port)
    defer { client.close() }
    try #require(waiting.wait(timeout: .now() + 5) == .success)
    try client.write(Data([42]))
    try #require(received.wait(timeout: .now() + 5) == .success)
    listener.stop()
    try #require(finished.wait(timeout: .now() + 5) == .success)
  }

  @Test
  func engineExitStopsOnlyItsOwnedHelperGroup() throws {
    let unrelated = try RouterEngineProcess(
      executable: URL(filePath: "/bin/sleep"), arguments: ["30"], environment: [:])
    defer { unrelated.stop() }
    let engine = try RouterEngineProcess(
      executable: URL(filePath: "/bin/sh"),
      arguments: ["-c", "sleep 30 & printf '%s\\n' \"$!\"; read finished"],
      environment: ["PATH": "/usr/bin:/bin"])
    defer { engine.stop() }
    let received = try EngineLineReader(engine.output).next()
    let line = try #require(received)
    let helper = try #require(Int32(String(decoding: line, as: UTF8.self)))
    #expect(kill(helper, 0) == 0)
    try engine.input.write(contentsOf: Data("done\n".utf8))
    #expect(engine.wait() == 0)
    for _ in 0..<100 where kill(helper, 0) == 0 { Thread.sleep(forTimeInterval: 0.01) }
    #expect(kill(helper, 0) == -1 && errno == ESRCH)
    #expect(kill(unrelated.pid, 0) == 0)
  }
}

private enum ListenerClientFailure: Error {
  case refused
}

private func listenerClient(port: UInt16) throws -> RouterSocket {
  let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
  guard descriptor >= 0 else { throw RouterFailure("Could not create the fixture client.") }
  let client = RouterSocket(descriptor)
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = port.bigEndian
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  let status = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard status == 0 else {
    if errno == ECONNREFUSED { throw ListenerClientFailure.refused }
    throw RouterFailure("Could not connect to the fixture listener.")
  }
  return client
}
