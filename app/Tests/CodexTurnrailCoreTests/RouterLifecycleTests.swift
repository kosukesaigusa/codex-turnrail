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

  @Test
  func stoppingListenerReleasesItsAcceptWorker() throws {
    var listener: RouterListener? = try RouterListener()
    weak var retained = listener
    listener?.start { $0.close() }
    listener?.stop()
    listener = nil
    for _ in 0..<100 where retained != nil { Thread.sleep(forTimeInterval: 0.01) }
    #expect(retained == nil)
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
