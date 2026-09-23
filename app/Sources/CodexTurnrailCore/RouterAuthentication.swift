import Foundation

/// Obtain a validated access token through the official Engine's private protocol pipe.
///
/// The caller holds the account lock for the lifetime of the Engine client. Only the
/// official Engine reads and refreshes its saved credentials; Turnrail keeps the
/// returned access token in memory and never persists an inspection copy.
enum RouterAuthentication {
  static func read(
    expectedEmail: String, now: Date,
    request: (String, [String: Any]) throws -> [String: Any]
  ) throws -> RouterCredential {
    var credential = try token(
      request("getAuthStatus", ["includeToken": true, "refreshToken": false]))
    if credential.expiresAt.timeIntervalSince(now) <= 600 {
      let refreshed = try token(
        request("getAuthStatus", ["includeToken": true, "refreshToken": true]))
      guard refreshed.accountID == credential.accountID else {
        throw RouterFailure("Credential refresh changed workspace identity. Sign in again.")
      }
      credential = refreshed
    }
    guard credential.expiresAt > now else { throw RouterAccountUnavailable.loginRequired }
    let identity = try request("account/read", ["refreshToken": false])
    if identity["account"] is NSNull { throw RouterAccountUnavailable.loginRequired }
    let account = try RouterJSON.map(identity, "account")
    guard account["type"] as? String == "chatgpt",
      try RouterJSON.text(account, "email").lowercased() == expectedEmail.lowercased()
    else {
      throw RouterFailure("The saved authentication does not match this registered account.")
    }
    let route = try RouterJSON.map(identity, "workspaceRouting")
    guard try RouterJSON.text(route, "chatgptAccountId") == credential.accountID else {
      throw RouterFailure("The access token does not match the inspected workspace.")
    }
    guard route["backendOrigin"] as? String == "https://chatgpt.com",
      route["accountRoutingOverride"] as? String == "NO_CONSTRAINT"
    else {
      throw RouterFailure(
        "This account's workspace requires a routing policy that Turnrail has not verified.")
    }
    return credential
  }

  private static func token(_ response: [String: Any]) throws -> RouterCredential {
    guard response["authMethod"] as? String == "chatgpt",
      let access = response["authToken"] as? String, !access.isEmpty
    else { throw RouterAccountUnavailable.loginRequired }
    let claims = try AccountCredentialStore.claims(access)
    guard let expiry = claims["exp"] as? Double, expiry.isFinite else {
      throw RouterFailure("The access token has no valid expiry.")
    }
    let identity = try RouterJSON.map(claims, "https://api.openai.com/auth")
    return RouterCredential(
      accessToken: access, accountID: try RouterJSON.text(identity, "chatgpt_account_id"),
      expiresAt: Date(timeIntervalSince1970: expiry))
  }
}
