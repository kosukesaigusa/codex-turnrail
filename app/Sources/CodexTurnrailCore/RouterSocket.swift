import CryptoKit
import Darwin
import Foundation

/// Bounded loopback-only HTTP and RFC 6455 framing; upstream TLS uses URLSession.
final class RouterSocket: @unchecked Sendable {
  let descriptor: Int32
  private let lock = NSLock()
  private let writeLock = NSLock()
  private var closed = false
  private var closeHandler: (@Sendable () -> Void)?

  init(_ descriptor: Int32) {
    self.descriptor = descriptor
    var yes: Int32 = 1
    setsockopt(
      descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
    var timeout = timeval(tv_sec: 30, tv_usec: 0)
    setsockopt(
      descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    setsockopt(
      descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
  }

  deinit { Darwin.close(descriptor) }

  func onClose(_ handler: @escaping @Sendable () -> Void) {
    let callNow = lock.withLock {
      closeHandler = handler
      return closed
    }
    if callNow { handler() }
  }

  var isClosed: Bool { lock.withLock { closed } }

  func close() {
    let handler = lock.withLock { () -> (@Sendable () -> Void)? in
      guard !closed else { return nil }
      closed = true
      shutdown(descriptor, SHUT_RDWR)
      return closeHandler
    }
    handler?()
  }

  func read(_ count: Int) throws -> Data {
    guard count >= 0, count <= 64 * 1024 * 1024 else {
      throw RouterFailure("Unsupported socket message size.")
    }
    var data = Data(count: count)
    var offset = 0
    while offset < count {
      let size = data.withUnsafeMutableBytes { buffer in
        recv(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
      }
      if size < 0 && errno == EINTR { continue }
      guard size > 0 else { throw RouterFailure("The local connection closed or timed out.") }
      offset += size
    }
    return data
  }

  func write(_ data: Data) throws {
    try writeLock.withLock {
      var offset = 0
      while offset < data.count {
        let size = data.withUnsafeBytes {
          send(descriptor, $0.baseAddress!.advanced(by: offset), data.count - offset, 0)
        }
        if size < 0 && errno == EINTR { continue }
        guard size > 0 else {
          throw RouterFailure("The local connection could not receive the response.")
        }
        offset += size
      }
    }
  }

  func request() throws -> RouterHTTPRequest {
    var head = Data()
    while !head.suffix(4).elementsEqual([13, 10, 13, 10]) {
      head.append(try read(1))
      guard head.count <= 32768 else {
        throw RouterFailure("HTTP headers exceed the supported size.")
      }
    }
    guard let text = String(data: head, encoding: .utf8) else {
      throw RouterFailure("Invalid HTTP header encoding.")
    }
    let lines = text.components(separatedBy: "\r\n")
    let parts = lines[0].split(separator: " ")
    guard parts.count == 3, parts[2] == "HTTP/1.1" else {
      throw RouterFailure("Unsupported HTTP request.")
    }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() where !line.isEmpty {
      guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
        throw RouterFailure("Invalid HTTP header.")
      }
      let name = line[..<colon].lowercased()
      guard headers[name] == nil else { throw RouterFailure("Duplicate HTTP header.") }
      headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    guard headers["origin"] == nil, headers["transfer-encoding"] == nil else {
      throw RouterFailure(
        "Browser-origin and chunked requests are not supported by the private router.")
    }
    return RouterHTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers)
  }

  func reply(status: Int, body: [String: Any]) throws {
    try reply(status: status, data: RouterJSON.data(body))
  }

  func reply(status: Int, data: Data) throws {
    var response = Data(
      "HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        .utf8)
    response.append(data)
    try write(response)
  }

  func upgrade(_ request: RouterHTTPRequest) throws {
    guard request.method == "GET", request.headers["upgrade"]?.lowercased() == "websocket",
      request.headers["connection"]?.lowercased().split(separator: ",").contains(where: {
        $0.trimmingCharacters(in: .whitespaces) == "upgrade"
      }) == true,
      request.headers["sec-websocket-version"] == "13",
      let key = request.headers["sec-websocket-key"], Data(base64Encoded: key)?.count == 16,
      request.headers["content-length"] == nil
    else { throw RouterFailure("Invalid WebSocket handshake.") }
    let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
    let accept = Data(digest).base64EncodedString()
    try write(
      Data(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
          .utf8))
    // A desktop socket can stay idle between turns. Lifecycle shutdown interrupts recv.
    var timeout = timeval(tv_sec: 0, tv_usec: 0)
    setsockopt(
      descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
  }

  func message() throws -> Data? {
    var aggregate = Data()
    var fragmented = false
    while true {
      let prefix = [UInt8](try read(2))
      let final = prefix[0] & 0x80 != 0
      let opcode = prefix[0] & 0x0F
      guard prefix[0] & 0x70 == 0, prefix[1] & 0x80 != 0 else {
        throw RouterFailure("WebSocket frames must be masked and uncompressed.")
      }
      var length = UInt64(prefix[1] & 0x7F)
      if length == 126 {
        length = try read(2).reduce(0) { ($0 << 8) | UInt64($1) }
        guard length >= 126 else { throw RouterFailure("Noncanonical WebSocket length.") }
      } else if length == 127 {
        length = try read(8).reduce(0) { ($0 << 8) | UInt64($1) }
        guard length >= 65536 else { throw RouterFailure("Noncanonical WebSocket length.") }
      }
      guard length <= 64 * 1024 * 1024, UInt64(aggregate.count) + length <= 64 * 1024 * 1024 else {
        throw RouterFailure("WebSocket message exceeds the supported size.")
      }
      if opcode >= 8 {
        guard final, length <= 125 else { throw RouterFailure("Invalid WebSocket control frame.") }
      }
      let mask = [UInt8](try read(4))
      var payload = [UInt8](try read(Int(length)))
      for index in payload.indices { payload[index] ^= mask[index % 4] }
      switch opcode {
      case 8:
        guard payload.count != 1 else { throw RouterFailure("Invalid WebSocket close frame.") }
        try frame(Data(payload), opcode: 8)
        return nil
      case 9:
        try frame(Data(payload), opcode: 10)
        continue
      case 10: continue
      case 1:
        guard !fragmented else {
          throw RouterFailure("Interleaved WebSocket messages are invalid.")
        }
        fragmented = true
      case 0:
        guard fragmented else { throw RouterFailure("Unexpected WebSocket continuation.") }
      default: throw RouterFailure("Only JSON text WebSocket messages are supported.")
      }
      aggregate.append(contentsOf: payload)
      if final {
        guard String(data: aggregate, encoding: .utf8) != nil else {
          throw RouterFailure("Invalid WebSocket UTF-8.")
        }
        return aggregate
      }
    }
  }

  func frame(_ payload: Data, opcode: UInt8 = 1) throws {
    var data = Data([0x80 | opcode])
    if payload.count < 126 {
      data.append(UInt8(payload.count))
    } else if payload.count <= 65535 {
      data.append(126)
      data.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 255)])
    } else {
      data.append(127)
      let size = UInt64(payload.count)
      for shift in stride(from: 56, through: 0, by: -8) {
        data.append(UInt8((size >> shift) & 255))
      }
    }
    data.append(payload)
    try write(data)
  }
}

struct RouterHTTPRequest: Sendable {
  let method: String
  let path: String
  let headers: [String: String]
}

final class RouterListener: @unchecked Sendable {
  let port: UInt16
  private let descriptor: Int32
  private let lock = NSLock()
  private var stopped = false
  private var sockets: [UUID: RouterSocket] = [:]

  init() throws {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    self.descriptor = descriptor
    guard descriptor >= 0 else { throw RouterFailure("Could not create the loopback listener.") }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(descriptor, 32) == 0 else {
      Darwin.close(descriptor)
      throw RouterFailure("Could not bind the private loopback listener.")
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let status = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }
    guard status == 0 else {
      Darwin.close(descriptor)
      throw RouterFailure("Could not read the loopback port.")
    }
    port = UInt16(bigEndian: address.sin_port)
  }

  deinit { Darwin.close(descriptor) }

  func start(_ handle: @escaping @Sendable (RouterSocket) -> Void) {
    DispatchQueue(label: "Turnrail.listener").async {
      while !self.lock.withLock({ self.stopped }) {
        let fd = accept(self.descriptor, nil, nil)
        if fd < 0 {
          if errno == EINTR { continue }
          break
        }
        let connection = RouterSocket(fd)
        let id = UUID()
        let accepted = self.lock.withLock {
          guard !self.stopped, self.sockets.count < 64 else { return false }
          self.sockets[id] = connection
          return true
        }
        if !accepted {
          connection.close()
          continue
        }
        DispatchQueue(label: "Turnrail.connection.\(id)").async {
          handle(connection)
          connection.close()
          _ = self.lock.withLock { self.sockets.removeValue(forKey: id) }
        }
      }
    }
  }

  func stop() {
    let current = lock.withLock { () -> [RouterSocket] in
      guard !stopped else { return [] }
      stopped = true
      shutdown(descriptor, SHUT_RDWR)
      return Array(sockets.values)
    }
    for socket in current { socket.close() }
  }
}
