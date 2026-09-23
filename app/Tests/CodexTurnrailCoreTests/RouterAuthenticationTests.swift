import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterAuthenticationTests {
  private let now = Date(timeIntervalSince1970: 1_000)

  @Test
  func repeatedChecksOnlyReadCredentialsFromTheOfficialProtocol() throws {
    let status = try authentication(workspace: "work", expiry: 10_000)
    for minute in 0..<4 {
      var methods: [String] = []
      let credential = try RouterAuthentication.read(
        expectedEmail: "OWNER@example.com", now: now.addingTimeInterval(Double(minute) * 60)
      ) { method, params in
        methods.append(method)
        #expect(params["refreshToken"] as? Bool == false)
        switch method {
        case "getAuthStatus":
          #expect(params["includeToken"] as? Bool == true)
          return status
        case "account/read": return identity(workspace: "work")
        default: throw RouterFailure("Unexpected authentication mutation.")
        }
      }
      #expect(credential.accountID == "work")
      #expect(methods == ["getAuthStatus", "account/read"])
    }
  }

  @Test
  func nearExpiryTokenIsRefreshedOnceByTheOfficialEngine() throws {
    var reads = 0
    let credential = try RouterAuthentication.read(expectedEmail: "owner@example.com", now: now) {
      method, params in
      if method == "account/read" { return identity(workspace: "work") }
      #expect(method == "getAuthStatus")
      #expect(params["refreshToken"] as? Bool == (reads == 1))
      reads += 1
      return try authentication(workspace: "work", expiry: reads == 1 ? 1_100 : 10_000)
    }
    #expect(reads == 2)
    #expect(credential.expiresAt == Date(timeIntervalSince1970: 10_000))
  }

  @Test
  func refreshCannotChangeWorkspaceOrReturnAnExpiredToken() throws {
    for invalid in [
      try authentication(workspace: "another", expiry: 10_000),
      try authentication(workspace: "work", expiry: 999),
      ["authMethod": "chatgpt", "authToken": NSNull()],
    ] {
      var reads = 0
      #expect(throws: (any Error).self) {
        try RouterAuthentication.read(expectedEmail: "owner@example.com", now: now) {
          method, _ in
          #expect(method == "getAuthStatus")
          reads += 1
          return reads == 1 ? try authentication(workspace: "work", expiry: 1_100) : invalid
        }
      }
      #expect(reads == 2)
    }
  }

  @Test
  func identityAndWorkspacePolicyMustMatchTheExportedToken() throws {
    var differentEmail = identity(workspace: "work")
    differentEmail["account"] = ["type": "chatgpt", "email": "another@example.com"]
    var differentBackend = identity(workspace: "work")
    differentBackend["workspaceRouting"] = [
      "chatgptAccountId": "work", "backendOrigin": "https://unverified.invalid",
      "accountRoutingOverride": "NO_CONSTRAINT",
    ]
    var restricted = identity(workspace: "work")
    restricted["workspaceRouting"] = [
      "chatgptAccountId": "work", "backendOrigin": "https://chatgpt.com",
      "accountRoutingOverride": "us",
    ]
    for invalid in [
      differentEmail, identity(workspace: "another"), differentBackend, restricted,
      ["account": NSNull()], ["account": ["type": "chatgpt", "email": "owner@example.com"]],
    ] {
      #expect(throws: (any Error).self) {
        try RouterAuthentication.read(expectedEmail: "owner@example.com", now: now) {
          method, _ in
          method == "getAuthStatus"
            ? try authentication(workspace: "work", expiry: 10_000) : invalid
        }
      }
    }
  }

  @Test
  func absentMalformedOrNonChatGPTTokensFailWithoutAnotherAuthenticationPath() throws {
    for response: [String: Any] in [
      [:], ["authMethod": "chatgpt", "authToken": NSNull()],
      ["authMethod": "apiKey", "authToken": "synthetic"],
      ["authMethod": "chatgpt", "authToken": "malformed"],
      ["authMethod": "chatgpt", "authToken": "header.e30.signature"],
    ] {
      var requests = 0
      #expect(throws: (any Error).self) {
        try RouterAuthentication.read(expectedEmail: "owner@example.com", now: now) { _, _ in
          requests += 1
          return response
        }
      }
      #expect(requests == 1)
    }
  }

  @Test
  func engineFailureDoesNotRetryAuthenticationOrReadAnotherStore() throws {
    enum ReadFailure: Error { case denied }
    var requests = 0
    #expect(throws: ReadFailure.self) {
      try RouterAuthentication.read(expectedEmail: "owner@example.com", now: now) { _, _ in
        requests += 1
        throw ReadFailure.denied
      }
    }
    #expect(requests == 1)
  }

  private func authentication(workspace: String, expiry: Int) throws -> [String: Any] {
    let claims: [String: Any] = [
      "exp": expiry, "https://api.openai.com/auth": ["chatgpt_account_id": workspace],
    ]
    let payload = try RouterJSON.data(claims).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return ["authMethod": "chatgpt", "authToken": "header." + payload + ".signature"]
  }

  private func identity(workspace: String) -> [String: Any] {
    [
      "account": ["type": "chatgpt", "email": "owner@example.com"],
      "workspaceRouting": [
        "chatgptAccountId": workspace, "backendOrigin": "https://chatgpt.com",
        "accountRoutingOverride": "NO_CONSTRAINT",
      ],
    ]
  }
}
