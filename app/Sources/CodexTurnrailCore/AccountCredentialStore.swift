import CryptoKit
import Darwin
import Foundation
import Security

/// Reads the official CLI's Keychain entry without introducing an auth.json store.
public struct AccountCredentialStore: Sendable {
  public init() {}

  /// Serialize official refreshes and validated sign-in commits across the app and router.
  static func withExclusiveAccess<T>(to home: URL, _ body: () throws -> T) throws -> T {
    let descriptor = open(
      home.appending(path: ".turnrail-auth.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw RouterFailure("Could not lock account authentication.") }
    defer {
      flock(descriptor, LOCK_UN)
      Darwin.close(descriptor)
    }
    let deadline = Date().addingTimeInterval(60)
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else {
        throw RouterFailure("Account authentication is busy. Try again after sign-in finishes.")
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return try body()
  }

  static func key(for home: URL) throws -> String {
    guard home.path.hasPrefix("/"), FileManager.default.fileExists(atPath: home.path) else {
      throw RouterFailure("The account authentication directory is missing.")
    }
    let canonical = home.resolvingSymlinksInPath().standardizedFileURL.path
    return "cli|" + RouterJSON.hash(Data(canonical.utf8)).prefix(16)
  }

  private func query(_ home: URL) throws -> [String: Any] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "Codex Auth", kSecAttrAccount as String: try Self.key(for: home),
    ]
    return query
  }

  func read(_ home: URL) throws -> Data? {
    var query = try query(home)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw RouterFailure("Keychain access failed (\(status)).")
    }
    return data
  }

  func write(_ data: Data, to home: URL) throws {
    let query = try query(home)
    let status = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var entry = query
      entry[kSecValueData as String] = data
      guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else {
        throw RouterFailure("Could not save the verified account in Keychain.")
      }
    } else if status != errSecSuccess {
      throw RouterFailure("Could not update the verified account in Keychain (\(status)).")
    }
  }

  func remove(_ home: URL) throws {
    let status = SecItemDelete(try query(home) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw RouterFailure("Could not remove temporary Keychain credentials (\(status)).")
    }
  }

  static func claims(_ jwt: String) throws -> [String: Any] {
    let pieces = jwt.split(separator: ".", omittingEmptySubsequences: false)
    guard pieces.count == 3 else { throw RouterFailure("Invalid account token format.") }
    var base64 = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64) else {
      throw RouterFailure("Invalid account token claims.")
    }
    return try RouterJSON.object(data)
  }

  static func validate(_ data: Data, expectedEmail: String, now: Date) throws -> RouterCredential {
    let credential = try decode(data, expectedEmail: expectedEmail)
    guard credential.expiresAt > now else {
      throw RouterAccountUnavailable.loginRequired
    }
    return credential
  }

  static func decode(_ data: Data, expectedEmail: String) throws -> RouterCredential {
    let tokens = try RouterJSON.map(RouterJSON.object(data), "tokens")
    let access = try RouterJSON.text(tokens, "access_token")
    let identity = try claims(RouterJSON.text(tokens, "id_token"))
    let account = try RouterJSON.text(tokens, "account_id")
    guard try RouterJSON.text(identity, "email").lowercased() == expectedEmail.lowercased(),
      try RouterJSON.text(
        RouterJSON.map(identity, "https://api.openai.com/auth"), "chatgpt_account_id") == account
    else { throw RouterFailure("The signed-in account does not match the registered account.") }
    let accessClaims = try claims(access)
    guard let expiry = accessClaims["exp"] as? Double else {
      throw RouterFailure("The access token has no expiry.")
    }
    let accessIdentity = try RouterJSON.map(accessClaims, "https://api.openai.com/auth")
    guard try RouterJSON.text(accessIdentity, "chatgpt_account_id") == account else {
      throw RouterFailure("Access token workspace does not match the registered authentication.")
    }
    return RouterCredential(
      accessToken: access, accountID: account, expiresAt: Date(timeIntervalSince1970: expiry))
  }

  /// Validate before committing, so a wrong-account login never replaces saved credentials.
  public func promote(from temporaryHome: URL, to destination: URL, expectedEmail: String) throws {
    guard let data = try read(temporaryHome) else {
      throw RouterFailure("Login did not save an account.")
    }
    _ = try Self.validate(data, expectedEmail: expectedEmail, now: Date())
    try Self.withExclusiveAccess(to: destination) { try write(data, to: destination) }
  }
}

struct RouterCredential: Sendable {
  let accessToken: String
  let accountID: String
  let expiresAt: Date
  var headers: [String: String] {
    ["Authorization": "Bearer " + accessToken, "ChatGPT-Account-Id": accountID]
  }
}
