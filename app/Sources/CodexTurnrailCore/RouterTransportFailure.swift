import Foundation

/// Transport diagnostics contain protocol and numeric OS codes, never server text or URLs.
struct RouterTransportFailure: LocalizedError {
  enum Phase: String, Codable { case check, send, receive }
  enum Cause: String, Codable {
    case transport, keepAlive, probe, sendTimeout, receiveTimeout, localClose
  }
  var phase: Phase
  var cause = Cause.transport
  let domain: String?
  let code: Int?
  let closeCode: Int?
  var connectionAgeMS: Int?
  var request: RouterTransportObservation?
  var reference: String?
  var diagnosticWriteFailed = false

  init(phase: Phase, error: Error, closeCode: URLSessionWebSocketTask.CloseCode) {
    self.phase = phase
    let failure = error as NSError
    if [NSURLErrorDomain, NSPOSIXErrorDomain].contains(failure.domain) {
      domain = failure.domain
      code = failure.code
    } else {
      domain = nil
      code = nil
    }
    self.closeCode = (1000...4999).contains(closeCode.rawValue) ? closeCode.rawValue : nil
  }

  var diagnostic: String {
    var fields = ["phase: \(phase.rawValue)"]
    if let domain, let code { fields.append("\(domain): \(code)") }
    if let closeCode { fields.append("close: \(closeCode)") }
    if cause != .transport { fields.append("source: \(cause.rawValue)") }
    if let request {
      fields.append("request: \(request.kind.rawValue)")
      fields.append("events: \(request.receivedEvents)")
    }
    if let reference { fields.append("ref: \(reference)") }
    if diagnosticWriteFailed { fields.append("diagnostic storage unavailable") }
    return fields.joined(separator: "; ")
  }

  var errorDescription: String? {
    let message: String
    switch phase {
    case .check:
      message = "The bound account connection was unavailable before sending. No request was sent."
    case .send:
      message = "The bound account connection failed while sending. No request was replayed."
    case .receive:
      message = "The bound account connection was interrupted. No request was replayed."
    }
    return "\(message) [\(diagnostic)]"
  }
}
