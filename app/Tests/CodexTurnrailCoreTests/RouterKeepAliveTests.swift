import Darwin
import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterKeepAliveTests {
  @Test(.timeLimit(.minutes(1)))
  func quietResponseSurvivesPeerIdleDeadlineWithoutReplay() throws {
    let server = try QuietTransportServer(mode: .delayed)
    defer { server.stop() }
    let client = server.connect()
    defer { client.close() }
    try client.checkConnection()
    let request = Data(#"{"type":"response.create","input":[]}"#.utf8)
    try client.send(request)
    #expect(try client.receive() == request)
    #expect(server.requests == [request])
  }

  @Test(.timeLimit(.minutes(1)))
  func idleConnectionStaysAliveBetweenModelRequests() throws {
    let server = try QuietTransportServer(mode: .echo)
    defer { server.stop() }
    let client = server.connect()
    defer { client.close() }
    try client.checkConnection()
    let request = Data(#"{"type":"response.create","input":[]}"#.utf8)
    try client.send(request)
    #expect(try client.receive() == request)
    Thread.sleep(forTimeInterval: 1.4)
    try client.checkConnection()
    try client.send(request)
    #expect(try client.receive() == request)
    #expect(server.requests == [request, request])
  }

  @Test(.timeLimit(.minutes(1)))
  func missingPongWakesReceiverAndPreservesTheFirstCause() throws {
    let server = try QuietTransportServer(mode: .stalled)
    defer { server.stop() }
    let client = server.connect()
    defer { client.close() }
    try client.checkConnection()
    let request = Data(#"{"type":"response.create","input":[]}"#.utf8)
    try client.send(request)
    do {
      _ = try client.receive()
      Issue.record("A stalled peer unexpectedly produced a response.")
    } catch let failure as RouterTransportFailure {
      #expect(failure.phase == .receive)
      #expect(failure.cause == .keepAlive)
      #expect(failure.code == URLError.timedOut.rawValue)
    }
    // Cancellation callbacks must not replace the heartbeat failure or permit reuse.
    client.close()
    do {
      try client.checkConnection()
      Issue.record("A failed transport became reusable.")
    } catch let failure as RouterTransportFailure {
      #expect(failure.phase == .check)
      #expect(failure.cause == .keepAlive)
    }
    #expect(throws: RouterTransportFailure.self) { try client.send(request) }
    #expect(server.requests == [request])
  }

  @Test(.timeLimit(.minutes(1)))
  func healthyQuietConnectionWaitsForOutputUntilCancelled() throws {
    let server = try QuietTransportServer(mode: .silent)
    defer { server.stop() }
    let client = server.connect()
    defer { client.close() }
    try client.checkConnection()
    let request = Data(#"{"type":"response.create","input":[]}"#.utf8)
    try client.send(request)
    try #require(server.requestReceived.wait(timeout: .now() + 2) == .success)
    let result = RouterAsyncResult<Data>()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      result.complete(Result { try client.receive() })
      finished.signal()
    }
    // Multiple heartbeat cycles must neither produce model output nor end the wait.
    #expect(finished.wait(timeout: .now() + 1.4) == .timedOut)
    client.close()
    try #require(finished.wait(timeout: .now() + 2) == .success)
    do {
      _ = try result.wait()
      Issue.record("The cancelled transport produced a response.")
    } catch let failure as RouterTransportFailure {
      #expect(failure.phase == .receive)
      #expect(failure.cause == .localClose)
    }
    #expect(server.requests == [request])
  }

  @Test(.timeLimit(.minutes(1)))
  func cancelledConnectionRejectsLaterReceiveWithoutReplay() throws {
    let server = try QuietTransportServer(mode: .silent)
    defer { server.stop() }
    let client = server.connect()
    try client.checkConnection()
    let request = Data(#"{"type":"response.create","input":[]}"#.utf8)
    try client.send(request)
    try #require(server.requestReceived.wait(timeout: .now() + 2) == .success)
    client.close()
    do {
      _ = try client.receive()
      Issue.record("The cancelled transport remained active.")
    } catch let failure as RouterTransportFailure {
      #expect(failure.phase == .receive)
      #expect(failure.cause == .localClose)
    }
    #expect(server.requests == [request])
  }
}

/// A short peer idle deadline stands in for an intermediary closing a quiet connection.
private final class QuietTransportServer: @unchecked Sendable {
  enum Mode { case echo, delayed, silent, stalled }
  private let listener: RouterListener
  private let lock = NSLock()
  private var received: [Data] = []
  private var replies: [DispatchWorkItem] = []
  private let stopped = DispatchSemaphore(value: 0)
  let requestReceived = DispatchSemaphore(value: 0)
  var requests: [Data] { lock.withLock { received } }

  init(mode: Mode) throws {
    listener = try RouterListener()
    listener.start { [weak self] socket in
      guard let self else { return }
      do {
        try socket.upgrade(socket.request())
        var timeout = timeval(tv_sec: 0, tv_usec: 600_000)
        guard
          setsockopt(
            socket.descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))) == 0
        else { throw RouterFailure("Could not set the fixture idle deadline.") }
        while let body = try socket.message() {
          self.lock.withLock { self.received.append(body) }
          self.requestReceived.signal()
          switch mode {
          case .delayed:
            let reply = DispatchWorkItem { try? socket.frame(body) }
            self.lock.withLock { self.replies.append(reply) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.4, execute: reply)
          case .echo:
            try socket.frame(body)
          case .silent: break
          case .stalled:
            self.stopped.wait()
            return
          }
        }
      } catch {}
    }
  }

  func connect() -> RouterWebSocket {
    RouterWebSocket(
      accountID: UUID(),
      request: URLRequest(url: URL(string: "ws://127.0.0.1:\(listener.port)/fixture")!),
      policy: RouterConnectionPolicy(keepAlive: 0.05, probe: 0.4, send: 1))
  }

  func stop() {
    stopped.signal()
    listener.stop()
    lock.withLock { for reply in replies { reply.cancel() } }
  }
}
