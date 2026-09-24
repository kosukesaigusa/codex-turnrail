import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterTransportTests {
  @Test(.timeLimit(.minutes(1)))
  func livenessProbeDoesNotSendInferenceAndDetectsAnExpiredConnection() throws {
    let server = try TransportServer(closeAfterRequest: false)
    defer { server.stop() }
    let client = server.connect()
    defer { client.close() }
    try #require(throws: Never.self, "Initial connection probe") {
      try client.checkConnection()
    }
    #expect(server.requests.isEmpty)
    let body = Data(#"{"type":"response.create","input":[]}"#.utf8)
    try client.send(body)
    #expect(try client.receive() == body)
    // Check a previously used connection, then simulate expiry while idle.
    try #require(throws: Never.self, "Connection probe after a complete response") {
      try client.checkConnection()
    }
    #expect(server.requests == [body])
    server.stop()
    do {
      try client.checkConnection()
      Issue.record("A disconnected server passed its liveness check.")
    } catch let failure as RouterTransportFailure {
      #expect(failure.phase == .check)
    }
    #expect(server.requests == [body])
  }

  @Test(.timeLimit(.minutes(1)))
  func disconnectionAfterSendDoesNotReplayTheRequest() throws {
    let server = try TransportServer(closeAfterRequest: true)
    defer { server.stop() }
    let client = server.connect()
    defer { client.close() }
    try client.checkConnection()
    let body = Data(#"{"type":"response.create","input":[]}"#.utf8)
    try client.send(body)
    do {
      _ = try client.receive()
      Issue.record("The closed connection unexpectedly returned a response.")
    } catch let failure as RouterTransportFailure {
      #expect(failure.phase == .receive)
    }
    #expect(server.requests == [body])
  }

  @Test
  func transportDiagnosticsExcludeCredentialsAndFreeFormErrors() throws {
    let secret = "PRIVATE_ACCOUNT_TOKEN_AND_URL"
    let details: [String: Any] = [
      NSLocalizedDescriptionKey: secret, NSURLErrorFailingURLStringErrorKey: secret,
      NSUnderlyingErrorKey: NSError(domain: secret, code: 99),
    ]
    let failure = RouterTransportFailure(
      phase: .receive,
      error: NSError(domain: NSURLErrorDomain, code: -1005, userInfo: details),
      closeCode: .goingAway)
    #expect(failure.diagnostic.contains("NSURLErrorDomain: -1005"))
    #expect(failure.diagnostic.contains("close: 1001"))
    #expect(!failure.localizedDescription.contains(secret))
    let unknown = RouterTransportFailure(
      phase: .check, error: NSError(domain: secret, code: 99, userInfo: details),
      closeCode: .invalid)
    #expect(!unknown.localizedDescription.contains(secret))
  }
}

/// Uses real Foundation WebSockets against an in-process loopback server.
private final class TransportServer: @unchecked Sendable {
  private let listener: RouterListener
  private let lock = NSLock()
  private var received: [Data] = []
  var requests: [Data] { lock.withLock { received } }

  init(closeAfterRequest: Bool) throws {
    listener = try RouterListener()
    listener.start { [weak self] socket in
      guard let self else { return }
      do {
        try socket.upgrade(socket.request())
        while let body = try socket.message() {
          self.lock.withLock { self.received.append(body) }
          if closeAfterRequest { return }
          try socket.frame(body)
        }
      } catch {}
    }
  }

  func connect() -> RouterWebSocket {
    RouterWebSocket(
      accountID: UUID(),
      request: URLRequest(url: URL(string: "ws://127.0.0.1:\(listener.port)/fixture")!),
      policy: .live)
  }

  func stop() { listener.stop() }
}
