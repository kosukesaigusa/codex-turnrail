import Foundation

/// Native web.run uses HTTP on the model provider, with an already bound turn.
enum RouterSearch {
  static let maximumBytes = 64 * 1024 * 1024

  static func request(
    body: Data, headers: [String: String], account: RouterAccountSnapshot
  ) -> URLRequest {
    var request = URLRequest(
      url: URL(string: "https://chatgpt.com/backend-api/codex/alpha/search")!)
    request.httpMethod = "POST"
    request.httpBody = body
    request.allHTTPHeaderFields = account.credential.headers
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    for name in ["originator", "version", "x-codex-turn-metadata"] {
      if let value = headers[name] { request.setValue(value, forHTTPHeaderField: name) }
    }
    return request
  }

  static func send(_ request: URLRequest) throws -> Data {
    let (data, status) = try RouterHTTP.exchange(request, maximumBytes: maximumBytes)
    guard status == 200 else {
      throw RouterFailure("Web search failed for the bound account (HTTP \(status)).")
    }
    return data
  }
}
