import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterTransportLogTests {
  @Test
  func archiveKeepsBoundedPrivateDiagnosticsWithoutRequestContent() throws {
    let root = try RouterTestDirectory()
    let log = RouterTransportLog(root: root.url)
    let secret = "PRIVATE_TOKEN_EMAIL_URL_AND_MODEL_CONTENT"
    var failure = RouterTransportFailure(
      phase: .receive,
      error: NSError(
        domain: NSPOSIXErrorDomain, code: 57, userInfo: [NSLocalizedDescriptionKey: secret]),
      closeCode: .noStatusReceived)
    var progress = RouterRequestProgress(
      kind: .compaction, connectionReused: true, requestBytes: 512)
    progress.received(type: "response.created")
    progress.received(type: secret)
    failure.request = progress.snapshot()
    let first = try log.record(failure)
    for _ in 0..<RouterTransportLog.maximumEntries { _ = try log.record(failure) }
    let file = root.url.appending(path: "transport-diagnostics.json")
    let data = try Data(contentsOf: file)
    let text = String(decoding: data, as: UTF8.self)
    let archive = try RouterJSON.object(data)
    let entries = try RouterJSON.array(archive, "entries")
    #expect(entries.count == RouterTransportLog.maximumEntries)
    #expect(!text.contains(secret))
    #expect(!text.contains(first))
    let last = try #require(entries.last)
    let request = try RouterJSON.map(last, "request")
    #expect(request["kind"] as? String == "compaction")
    #expect(request["receivedEvents"] as? Int == 2)
    #expect(request["responseStarted"] as? Bool == true)
    #expect(request["connectionReused"] as? Bool == true)
    #expect(request["requestBytes"] as? Int == 512)
    #expect(last["code"] as? Int == 57)
    #expect(last["closeCode"] as? Int == 1005)
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test
  func unknownErrorsCannotLeakIntoDiagnostics() throws {
    let root = try RouterTestDirectory()
    let secret = "PRIVATE_ERROR_DOMAIN"
    let failure = RouterTransportFailure(
      phase: .send, error: NSError(domain: secret, code: 99), closeCode: .invalid)
    _ = try RouterTransportLog(root: root.url).record(failure)
    let data = try Data(contentsOf: root.url.appending(path: "transport-diagnostics.json"))
    let entry = try #require(RouterJSON.array(RouterJSON.object(data), "entries").first)
    #expect(entry["domain"] == nil)
    #expect(entry["code"] == nil)
    #expect(entry["closeCode"] == nil)
    #expect(entry["request"] == nil)
    #expect(!String(decoding: data, as: UTF8.self).contains(secret))
  }

  @Test
  func corruptOrLinkedArchivesFailWithoutReplacingExistingFiles() throws {
    let root = try RouterTestDirectory()
    let log = RouterTransportLog(root: root.url)
    let file = root.url.appending(path: "transport-diagnostics.json")
    let data = Data("NOT_A_VALID_ARCHIVE".utf8)
    try data.write(to: file)
    let failure = RouterTransportFailure(
      phase: .receive, error: URLError(.networkConnectionLost), closeCode: .invalid)
    #expect(throws: (any Error).self) { try log.record(failure) }
    #expect(try Data(contentsOf: file) == data)
    try FileManager.default.removeItem(at: file)
    let target = root.url.appending(path: "unrelated")
    try data.write(to: target)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    #expect(throws: (any Error).self) { try log.record(failure) }
    #expect(try Data(contentsOf: target) == data)
  }
}
