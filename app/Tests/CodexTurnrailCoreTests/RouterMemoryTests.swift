import Darwin
import Foundation
import Testing

@testable import CodexTurnrailCore

@Suite(.serialized)
struct RouterMemoryTests {
  @Test
  func repeatedRequestsReleaseTemporaryDataWithoutClosingTheConnection() throws {
    let root = try RouterTestDirectory()
    let runtime = try RouterRuntime(
      root: root.url, accounts: FixtureAccounts(root: root.url),
      connect: { _, _ in fatalError("Prewarm must not contact a model.") },
      reportFailure: { Issue.record(RouterFailure($0)) })
    runtime.start()
    defer { runtime.stop() }
    let client = try MemoryClient(runtime)
    defer { client.close() }
    let request = try autoreleasepool {
      try RouterJSON.data([
        "type": "response.create", "generate": false,
        "input": (0..<64).map {
          ["type": "message", "content": "synthetic-\($0)-" + String(repeating: "x", count: 2048)]
        },
        "client_metadata": [
          "x-codex-turn-metadata": try RouterJSON.string([
            "thread_id": "memory-prewarm", "request_kind": "prewarm",
          ])
        ],
      ])
    }
    try client.send(request)
    let initial = try client.receive()
    #expect(initial["type"] as? String == "response.created")
    #expect(try client.receive()["type"] as? String == "response.completed")
    let firstID = try RouterJSON.text(RouterJSON.map(initial, "response"), "id")
    let before = try footprint()
    for iteration in 1...256 {
      try client.send(request)
      #expect(try client.receive()["type"] as? String == "response.created")
      #expect(try client.receive()["type"] as? String == "response.completed")
      if iteration % 64 == 0 {
        try requireBoundedGrowth(before, label: "persistent requests", iteration: iteration)
      }
    }
    // The live metadata and content-addressed history must survive temporary-pool drainage.
    let history = try runtime.ledger.history(firstID, thread: "memory-prewarm")
    let input = try RouterJSON.array(history, "input")
    #expect(input.count == 64)
    #expect(try RouterJSON.text(input[63], "content").hasPrefix("synthetic-63-"))
  }

  @Test
  func streamingEventsReleaseTemporaryDataBeforeTheResponseCompletes() throws {
    let root = try RouterTestDirectory()
    let accounts = try FixtureAccounts(root: root.url)
    let upstream = try MemoryUpstream(account: accounts.first.account.id)
    let runtime = try RouterRuntime(
      root: root.url, accounts: accounts, connect: { _, _ in upstream },
      reportFailure: { Issue.record(RouterFailure($0)) })
    try runtime.ledger.bind("memory-stream/turn", account: accounts.first.account.id)
    runtime.start()
    defer { runtime.stop() }
    let client = try MemoryClient(runtime)
    defer { client.close() }
    let request = try autoreleasepool {
      try RouterJSON.data([
        "type": "response.create", "model": "gpt-5.6-luna",
        "input": [["type": "message", "content": "Synthetic memory fixture"]],
        "client_metadata": [
          "x-codex-turn-metadata": try RouterJSON.string([
            "thread_id": "memory-stream", "turn_id": "turn", "request_kind": "turn",
          ])
        ],
      ])
    }
    try client.send(request)
    #expect(try client.receive()["type"] as? String == "response.created")
    let before = try footprint()
    for iteration in 1...1024 {
      let event = try client.receive()
      #expect(event["type"] as? String == "response.output_text.delta")
      #expect((event["delta"] as? String)?.count == 256 * 1024)
      if iteration % 256 == 0 {
        try requireBoundedGrowth(before, label: "in-flight events", iteration: iteration)
      }
    }
    #expect(try client.receive()["type"] as? String == "response.completed")
    #expect(try runtime.ledger.bound("memory-stream/turn") == accounts.first.account.id)
  }

  @Test
  func repeatedHistoryReadsReleaseTemporaryDataWithinOneWorker() throws {
    let root = try RouterTestDirectory()
    let ledger = try RouterLedger(root: root.url)
    try autoreleasepool {
      try ledger.saveHistory(
        id: "memory-history",
        value: [
          "thread": "memory-history",
          "input": (0..<4).map {
            [
              "type": "message",
              "content": "synthetic-\($0)-" + String(repeating: "x", count: 65536),
            ]
          },
          "output": [[String: Any]](),
        ])
    }
    // Reproduce a worker that remains alive after each reconstructed history is consumed.
    try autoreleasepool {
      let before = try footprint()
      for iteration in 1...512 {
        let input = try RouterJSON.array(
          ledger.history("memory-history", thread: "memory-history"), "input")
        #expect(input.count == 4)
        #expect(try RouterJSON.text(input[3], "content").hasPrefix("synthetic-3-"))
        if iteration % 128 == 0 {
          try requireBoundedGrowth(before, label: "history reloads", iteration: iteration)
        }
      }
    }
  }

  private func requireBoundedGrowth(_ before: UInt64, label: String, iteration: Int) throws {
    let after = try footprint()
    let growth = after > before ? after - before : 0
    print("Router memory [\(label), \(iteration)]: growth \(growth / 1024 / 1024) MiB")
    // Leave room for concurrent small fixtures and allocator reuse; unbounded
    // autorelease retention exceeds this reserve well before the workload ends.
    try #require(growth < 96 * 1024 * 1024, "Temporary-data growth: \(growth) bytes")
  }

  private func footprint() throws -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    try #require(result == KERN_SUCCESS, "Could not measure the test process footprint.")
    return info.phys_footprint
  }
}

private final class MemoryClient {
  private let socket: RouterSocket

  init(_ runtime: RouterRuntime) throws {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw RouterFailure("Could not create the fixture socket.") }
    socket = RouterSocket(descriptor)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = runtime.listener.port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let status = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard status == 0 else { throw RouterFailure("Could not connect to the fixture router.") }
    try socket.write(
      Data(
        ("GET /\(runtime.secret)/v1/responses HTTP/1.1\r\nHost: 127.0.0.1\r\n"
          + "Connection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\n"
          + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n").utf8))
    var headers = Data()
    while !headers.suffix(4).elementsEqual([13, 10, 13, 10]) {
      headers.append(try socket.read(1))
      guard headers.count <= 8192 else { throw RouterFailure("Invalid fixture handshake.") }
    }
    try #require(String(decoding: headers, as: UTF8.self).hasPrefix("HTTP/1.1 101 "))
  }

  func send(_ data: Data) throws {
    try autoreleasepool {
      var frame = Data([0x81])
      if data.count < 126 {
        frame.append(0x80 | UInt8(data.count))
      } else if data.count <= 65535 {
        frame.append(0x80 | 126)
        frame.append(contentsOf: [UInt8(data.count >> 8), UInt8(data.count & 255)])
      } else {
        frame.append(0x80 | 127)
        for shift in stride(from: 56, through: 0, by: -8) {
          frame.append(UInt8((UInt64(data.count) >> shift) & 255))
        }
      }
      let mask: [UInt8] = [1, 2, 3, 4]
      frame.append(contentsOf: mask)
      frame.append(contentsOf: data.enumerated().map { $0.element ^ mask[$0.offset % 4] })
      try socket.write(frame)
    }
  }

  func receive() throws -> [String: Any] {
    try autoreleasepool {
      let prefix = [UInt8](try socket.read(2))
      try #require(prefix[0] == 0x81 && prefix[1] & 0x80 == 0)
      var length = UInt64(prefix[1] & 127)
      if length == 126 {
        length = try socket.read(2).reduce(0) { ($0 << 8) | UInt64($1) }
      } else if length == 127 {
        length = try socket.read(8).reduce(0) { ($0 << 8) | UInt64($1) }
      }
      try #require(length <= 64 * 1024 * 1024)
      return try RouterJSON.object(socket.read(Int(length)))
    }
  }

  func close() { socket.close() }
}

private final class MemoryUpstream: RouterUpstream, @unchecked Sendable {
  let generation = "memory-fixture"
  let accountID: UUID
  private let lock = NSLock()
  private let created: Data
  private let delta: Data
  private let completed: Data
  private var cursor = 0
  private var closed = false

  init(account: UUID) throws {
    accountID = account
    created = try RouterJSON.data([
      "type": "response.created", "response": ["id": "memory-response"],
    ])
    delta = try RouterJSON.data([
      "type": "response.output_text.delta", "delta": String(repeating: "x", count: 256 * 1024),
    ])
    completed = try RouterJSON.data([
      "type": "response.completed", "response": ["id": "memory-response"],
    ])
  }

  func checkConnection() throws {}
  func send(_ data: Data) throws {}

  func receive() throws -> Data {
    try lock.withLock {
      guard !closed else { throw RouterFailure("The fixture connection closed.") }
      defer { cursor += 1 }
      switch cursor {
      case 0: return created
      case 1...1024: return delta
      case 1025: return completed
      default: throw RouterFailure("The fixture has no more events.")
      }
    }
  }

  func close() { lock.withLock { closed = true } }
}
