import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterServiceLogTests {
  @Test
  func unknownFieldsRemainDiagnosableWithoutSavingPrivateValues() throws {
    let root = try RouterTestDirectory()
    let log = RouterServiceLog(root: root.url)
    let failure = try RouterServiceFailure(event: [
      "type": "error", "error": ["type": NSNull(), "code": "PRIVATE_CODE", "reason": 42],
      "headers": ["authorization": "PRIVATE_TOKEN"], "message_id": "PRIVATE_ID",
    ])
    var progress = RouterRequestProgress(kind: .turn, connectionReused: true, requestBytes: 123)
    progress.received(type: "response.created")
    let reference = try log.record(failure, request: progress.snapshot(), transport: .http)
    let file = root.url.appending(path: "service-diagnostics.json")
    let data = try Data(contentsOf: file)
    let entry = try #require(RouterJSON.array(RouterJSON.object(data), "entries").first)
    #expect(entry["reference"] as? String == reference)
    #expect(entry["envelope"] as? String == "wrappedError")
    #expect(entry["statusState"] as? String == "missing")
    #expect(try RouterJSON.map(entry, "errorType")["state"] as? String == "null")
    #expect(try RouterJSON.map(entry, "code")["state"] as? String == "unrecognized")
    #expect(try RouterJSON.map(entry, "reason")["state"] as? String == "invalid")
    #expect(entry["permitsEngineRecovery"] as? Bool == false)
    #expect(try RouterJSON.map(entry, "request")["receivedEvents"] as? Int == 1)
    #expect(!String(decoding: data, as: UTF8.self).contains("PRIVATE_"))
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test
  func archivesStayBoundedAndRecognizedServiceCodesAreRetained() throws {
    let root = try RouterTestDirectory()
    let log = RouterServiceLog(root: root.url)
    let failure = try RouterServiceFailure(event: [
      "type": "error", "status": 503,
      "error": ["type": "service_unavailable_error", "code": "server_is_overloaded"],
    ])
    let first = try log.record(failure, request: nil, transport: .webSocket)
    for _ in 0..<RouterServiceLog.maximumEntries {
      _ = try log.record(failure, request: nil, transport: .webSocket)
    }
    let data = try Data(contentsOf: root.url.appending(path: "service-diagnostics.json"))
    let entries = try RouterJSON.array(RouterJSON.object(data), "entries")
    #expect(entries.count == RouterServiceLog.maximumEntries)
    #expect(!String(decoding: data, as: UTF8.self).contains(first))
    let last = try #require(entries.last)
    #expect(last["status"] as? Int == 503)
    #expect(last["permitsEngineRecovery"] as? Bool == true)
    #expect(try RouterJSON.map(last, "code")["value"] as? String == "server_is_overloaded")
  }

  @Test
  func corruptOrLinkedDiagnosticsAreNeverReplaced() throws {
    let root = try RouterTestDirectory()
    let file = root.url.appending(path: "service-diagnostics.json")
    let data = Data("INVALID_ARCHIVE".utf8)
    try data.write(to: file)
    let log = RouterServiceLog(root: root.url)
    let failure = try RouterServiceFailure(event: ["type": "error", "error": [:]])
    #expect(throws: (any Error).self) {
      try log.record(failure, request: nil, transport: .http)
    }
    #expect(try Data(contentsOf: file) == data)
    try FileManager.default.removeItem(at: file)
    let target = root.url.appending(path: "unrelated")
    try data.write(to: target)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    #expect(throws: (any Error).self) {
      try log.record(failure, request: nil, transport: .http)
    }
    #expect(try Data(contentsOf: target) == data)
  }
}
