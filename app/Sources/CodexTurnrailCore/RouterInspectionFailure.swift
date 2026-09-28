import Foundation

/// Inspection diagnostics never include free-form server text, URLs, or credentials.
enum RouterInspectionFailure {
  static func transport(_ error: Error) -> RouterFailure {
    let failure = error as NSError
    let detail: String
    if [NSURLErrorDomain, NSPOSIXErrorDomain].contains(failure.domain) {
      detail = "\(failure.domain): \(failure.code)"
    } else {
      detail = "transport cause unavailable"
    }
    return RouterFailure("The HTTP request failed. No request was replayed. [\(detail)]")
  }

  static func rpc(method: String, error: [String: Any]) -> RouterFailure {
    var detail: [String] = []
    if let code = error["code"] as? NSNumber,
      CFGetTypeID(code) != CFBooleanGetTypeID(), let value = Int(exactly: code.doubleValue)
    {
      detail.append("RPC: \(value)")
    }
    let reason: String
    switch error["message"] as? String {
    case "workspace routing discovery timed out": reason = "workspace routing timeout"
    case "workspace routing discovery failed": reason = "workspace routing unavailable"
    default: reason = "cause unavailable"
    }
    detail.append(reason)
    return RouterFailure(
      "The official Engine rejected \(method). [\(detail.joined(separator: "; "))]")
  }
}
