import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterEventStreamTests {
  @Test
  func sseFramingHandlesSplitUTF8DelimitersCommentsAndMultilineData() throws {
    var parser = RouterSSEParser()
    let source =
      ": keepalive\r\ndata: {\rdata: \"text\":\"日本語\"}\r\n\r\nevent: ignored\ndata: [DONE]\n\n"
    var events: [Data] = []
    for byte in source.utf8 { events += try parser.append(Data([byte])) }
    #expect(events == [Data("{\n\"text\":\"日本語\"}".utf8)])
    #expect(parser.bufferedBytes == 0)
    #expect(throws: (any Error).self) {
      _ = try parser.append(Data("data: ".utf8) + Data([255, 10, 10]))
    }
    #expect(throws: (any Error).self) {
      var bounded = RouterSSEParser()
      _ = try bounded.append(Data(count: RouterSSEParser.maximumBytes + 1))
    }
  }

  @Test
  func httpRequestsRequireCanonicalIdentityAndShareWebSocketDeliveryIdentity() throws {
    let metadata = try RouterJSON.string([
      "thread_id": "thread", "turn_id": "turn", "request_kind": "turn",
    ])
    let body: [String: Any] = [
      "stream": true, "model": "fixture", "input": [],
      "client_metadata": ["x-codex-turn-metadata": metadata],
    ]
    let converted = try RouterJSON.object(
      RouterModelStream.httpBody(RouterJSON.data(body), headers: [:]))
    #expect(converted["type"] as? String == "response.create")
    var ws = converted
    ws.removeValue(forKey: "stream")
    #expect(
      try RouterRequest.fingerprint(ws, input: [], turn: "thread/turn")
        == RouterRequest.fingerprint(converted, input: [], turn: "thread/turn"))
    for headers in [["x-codex-turn-metadata": "{}"], ["content-encoding": "zstd"]] {
      #expect(throws: (any Error).self) {
        try RouterModelStream.httpBody(RouterJSON.data(body), headers: headers)
      }
    }
    for field in ["stream", "client_metadata"] {
      var invalid = body
      invalid.removeValue(forKey: field)
      #expect(throws: (any Error).self) {
        try RouterModelStream.httpBody(RouterJSON.data(invalid), headers: [:])
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func realHTTPStreamsIncrementallyAndReportsEOFWithoutResubmitting() throws {
    let server = try EventStreamServer { socket, _ in
      try socket.write(
        Data(
          "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            .utf8))
      for chunk in ["data: {\"type\":\"response.", "created\"}\n\n"] {
        try socket.write(Data((String(chunk.utf8.count, radix: 16) + "\r\n" + chunk + "\r\n").utf8))
      }
      try socket.write(Data("0\r\n\r\n".utf8))
    }
    defer { server.stop() }
    let client = server.connect()
    defer { client.close() }
    try client.send(Self.body())
    #expect(try RouterJSON.object(client.receive())["type"] as? String == "response.created")
    do {
      _ = try client.receive()
      Issue.record("An incomplete HTTP stream unexpectedly succeeded.")
    } catch let failure as RouterTransportFailure {
      #expect(failure.permitsEngineRecovery)
    }
    #expect(server.requestCount == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func httpRejectionsStayTerminalAndDoNotExposeServerText() throws {
    let server = try EventStreamServer { socket, _ in
      try socket.reply(
        status: 401,
        body: [
          "error": [
            "code": "token_revoked", "type": "authentication_error",
            "message": "PRIVATE_SERVER_TEXT",
          ]
        ])
    }
    defer { server.stop() }
    let client = server.connect()
    defer { client.close() }
    try client.send(Self.body())
    do {
      _ = try client.receive()
      Issue.record("HTTP authentication rejection unexpectedly succeeded.")
    } catch let failure as RouterServiceFailure {
      #expect(failure.localizedDescription.contains("token_revoked"))
      #expect(!failure.localizedDescription.contains("PRIVATE_SERVER_TEXT"))
    }
    #expect(server.requestCount == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func cancellingAnHTTPWaitClosesTheSocketAndWakesTheReceiver() throws {
    let waiting = DispatchSemaphore(value: 0)
    let closed = DispatchSemaphore(value: 0)
    let server = try EventStreamServer { socket, _ in
      try socket.write(
        Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n".utf8)
      )
      socket.waitUntilClosed()
      waiting.signal()
      _ = try? socket.read(1)
      closed.signal()
    }
    defer { server.stop() }
    let client = server.connect()
    try client.send(Self.body())
    try #require(waiting.wait(timeout: .now() + 5) == .success)
    client.close()
    do {
      _ = try client.receive()
      Issue.record("A cancelled HTTP wait unexpectedly succeeded.")
    } catch let failure as RouterTransportFailure {
      #expect(!failure.permitsEngineRecovery)
      #expect(failure.cause == .localClose)
    }
    #expect(closed.wait(timeout: .now() + 5) == .success)
    #expect(server.requestCount == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func redirectsCannotForwardCredentialsToAnotherEndpoint() throws {
    let destination = try EventStreamServer { socket, _ in try socket.reply(status: 200, body: [:])
    }
    defer { destination.stop() }
    let location = destination.url.absoluteString
    let server = try EventStreamServer { socket, _ in
      try socket.write(
        Data(
          "HTTP/1.1 307 Redirect\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            .utf8))
    }
    defer { server.stop() }
    let client = server.connect()
    defer { client.close() }
    try client.send(Self.body())
    #expect(throws: RouterFailure.self) { try client.receive() }
    #expect(server.requestCount == 1)
    #expect(destination.requestCount == 0)
  }

  private static func body() throws -> Data {
    try RouterJSON.data([
      "type": "response.create", "stream": true, "input": [],
      "client_metadata": ["x-codex-turn-metadata": "SYNTHETIC_METADATA"],
    ])
  }
}

private final class EventStreamServer: @unchecked Sendable {
  private let listener: RouterListener
  private let lock = NSLock()
  private var count = 0
  var requestCount: Int { lock.withLock { count } }
  var url: URL { URL(string: "http://127.0.0.1:\(listener.port)/responses")! }

  init(handler: @escaping @Sendable (RouterSocket, Data) throws -> Void) throws {
    listener = try RouterListener()
    listener.start { [weak self] socket in
      do {
        let request = try socket.request()
        #expect(request.method == "POST")
        #expect(request.headers["x-codex-turn-metadata"] == "SYNTHETIC_METADATA")
        let length = try #require(request.headers["content-length"])
        let size = try #require(Int(length))
        let body = try socket.read(size)
        #expect(try RouterJSON.object(body)["type"] == nil)
        self?.lock.withLock { self?.count += 1 }
        try handler(socket, body)
      } catch { Issue.record(error) }
    }
  }

  func connect() -> RouterEventStream {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer SYNTHETIC_SECRET", forHTTPHeaderField: "Authorization")
    return RouterEventStream(accountID: UUID(), request: request)
  }

  func stop() { listener.stop() }
}
