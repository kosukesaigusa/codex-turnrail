import Foundation

/// Transport diagnostics contain protocol and numeric OS codes, never server text or URLs.
struct RouterTransportFailure: LocalizedError {
  enum Phase: String { case check, send, receive }
  let phase: Phase
  let diagnostic: String

  init(phase: Phase, error: Error, closeCode: URLSessionWebSocketTask.CloseCode) {
    self.phase = phase
    let failure = error as NSError
    var fields = ["phase: \(phase.rawValue)"]
    if [NSURLErrorDomain, NSPOSIXErrorDomain].contains(failure.domain) {
      fields.append("\(failure.domain): \(failure.code)")
    }
    if (1000...4999).contains(closeCode.rawValue) {
      fields.append("close: \(closeCode.rawValue)")
    }
    diagnostic = fields.joined(separator: "; ")
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
