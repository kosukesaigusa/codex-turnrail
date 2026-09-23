import Foundation

public struct AccountAuthenticationCommand: Equatable, Sendable {
  public let executableURL: URL
  public let arguments: [String]
  public let environment: [String: String]
  public let expectedEmail: String?

  public init(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    expectedEmail: String?
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.expectedEmail = expectedEmail
  }
}

public enum AccountAuthenticationCommandFactory {
  public static func makeLogin(
    engineURL: URL,
    authHomeURL: URL,
    expectedEmail: String?,
    inheritedEnvironment: [String: String]
  ) -> AccountAuthenticationCommand {
    make(
      engineURL: engineURL,
      authHomeURL: authHomeURL,
      arguments: ["login"],
      expectedEmail: expectedEmail,
      inheritedEnvironment: inheritedEnvironment
    )
  }

  public static func makeLogout(
    engineURL: URL,
    authHomeURL: URL,
    inheritedEnvironment: [String: String]
  ) -> AccountAuthenticationCommand {
    make(
      engineURL: engineURL,
      authHomeURL: authHomeURL,
      arguments: ["logout"],
      expectedEmail: nil,
      inheritedEnvironment: inheritedEnvironment
    )
  }

  private static func make(
    engineURL: URL,
    authHomeURL: URL,
    arguments: [String],
    expectedEmail: String?,
    inheritedEnvironment: [String: String]
  ) -> AccountAuthenticationCommand {
    var environment = inheritedEnvironment
    environment["CODEX_HOME"] = authHomeURL.path
    environment.removeValue(forKey: "CODEX_TURNRAIL_EXPECTED_EMAIL")
    environment.removeValue(forKey: "CODEX_TURNRAIL_ROOT")
    return AccountAuthenticationCommand(
      executableURL: engineURL,
      arguments: arguments + ["--config", "cli_auth_credentials_store=\"keyring\""],
      environment: environment,
      expectedEmail: expectedEmail
    )
  }
}
