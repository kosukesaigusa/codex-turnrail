import Foundation

/// Both official model transports share account binding, history and delivery decisions.
final class RouterModelStream {
  enum Transport { case webSocket, http }
  let socket: RouterSocket
  let transport: Transport
  private var started = false

  init(socket: RouterSocket, transport: Transport) {
    self.socket = socket
    self.transport = transport
  }

  func start() throws {
    if transport == .http, !started {
      try socket.write(
        Data(
          "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            .utf8))
      started = true
    }
  }

  func frame(_ data: Data) throws {
    switch transport {
    case .webSocket: try socket.frame(data)
    case .http:
      try start()
      // Canonical JSON escapes embedded newlines, preserving one SSE data field.
      let json = try RouterJSON.data(RouterJSON.object(data))
      try socket.write(Data("data: ".utf8) + json + Data("\n\n".utf8))
    }
  }

  func reject(message: String, policyViolation: Bool) throws {
    if transport == .webSocket {
      try frame(
        RouterJSON.data([
          "type": "error", "status": 400,
          "error": [
            "type": "invalid_request_error",
            "code": policyViolation ? "misalignment_policy_violation" : "turnrail_routing_stopped",
            "message": message,
          ],
        ]))
    } else {
      // SSE uses response.failed, not the WebSocket error envelope. invalid_prompt
      // is the Engine's terminal InvalidRequest classification; retain the actual
      // sanitized service reason in the message and the safety code when applicable.
      try frame(
        RouterJSON.data([
          "type": "response.failed",
          "response": [
            "error": [
              "code": policyViolation ? "misalignment_policy_violation" : "invalid_prompt",
              "message": message,
            ]
          ],
        ]))
    }
  }

  static func httpBody(_ data: Data, headers: [String: String]) throws -> Data {
    var body = try RouterJSON.object(data)
    guard body["type"] == nil, body["stream"] as? Bool == true,
      headers["content-encoding"] == nil
    else { throw RouterFailure("HTTP inference requires an uncompressed streaming request.") }
    // The Engine sends the same client metadata on both transports. Validate it
    // before normalizing the protocol envelope; never infer identity from a folder.
    body["type"] = "response.create"
    let metadata = try RouterRequest.metadata(body)
    if let header = headers["x-codex-turn-metadata"] {
      guard try RouterJSON.data(metadata) == RouterJSON.data(RouterJSON.object(Data(header.utf8)))
      else { throw RouterFailure("HTTP inference metadata disagrees with its body.") }
    }
    return try RouterJSON.data(body)
  }
}
