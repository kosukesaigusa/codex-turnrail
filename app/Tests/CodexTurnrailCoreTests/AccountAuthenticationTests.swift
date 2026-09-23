import Foundation
import Testing

@testable import CodexTurnrailCore

struct AccountAuthenticationTests {
  @Test
  func buildsAnAccountScopedKeyringLoginCommand() {
    let command = AccountAuthenticationCommandFactory.makeLogin(
      engineURL: URL(filePath: "/opt/turnrail/codex"),
      authHomeURL: URL(filePath: "/tmp/account/auth-home"),
      expectedEmail: nil,
      inheritedEnvironment: [:]
    )

    #expect(command.executableURL.path == "/opt/turnrail/codex")
    #expect(command.arguments == ["login", "--config", "cli_auth_credentials_store=\"keyring\""])
    #expect(command.environment == ["CODEX_HOME": "/tmp/account/auth-home"])
  }

  @Test
  func requiresTheRegisteredIdentityDuringReauthentication() {
    let command = AccountAuthenticationCommandFactory.makeLogin(
      engineURL: URL(filePath: "/opt/turnrail/codex"),
      authHomeURL: URL(filePath: "/tmp/account/auth-home"),
      expectedEmail: "registered@example.com",
      inheritedEnvironment: [
        "CODEX_HOME": "/tmp/unrelated/auth-home",
        "CODEX_TURNRAIL_ROOT": "/tmp/unrelated/routing",
        "CODEX_TURNRAIL_EXPECTED_EMAIL": "unrelated@example.com",
        "PATH": "/usr/bin:/bin",
      ]
    )

    #expect(command.expectedEmail == "registered@example.com")
    #expect(
      command.environment == [
        "CODEX_HOME": "/tmp/account/auth-home",
        "PATH": "/usr/bin:/bin",
      ])
  }

  @Test
  func doesNotConstrainANewAccountToAnInheritedIdentity() {
    let command = AccountAuthenticationCommandFactory.makeLogin(
      engineURL: URL(filePath: "/opt/turnrail/codex"),
      authHomeURL: URL(filePath: "/tmp/new-account/auth-home"),
      expectedEmail: nil,
      inheritedEnvironment: [
        "CODEX_TURNRAIL_EXPECTED_EMAIL": "unrelated@example.com",
        "PATH": "/usr/bin:/bin",
      ]
    )

    #expect(
      command.environment == [
        "CODEX_HOME": "/tmp/new-account/auth-home",
        "PATH": "/usr/bin:/bin",
      ])
  }

  @Test
  func buildsAnAccountScopedKeyringLogoutCommand() {
    let command = AccountAuthenticationCommandFactory.makeLogout(
      engineURL: URL(filePath: "/opt/turnrail/codex"),
      authHomeURL: URL(filePath: "/tmp/account/auth-home"),
      inheritedEnvironment: [
        "CODEX_TURNRAIL_ROOT": "/tmp/unrelated/routing",
        "CODEX_TURNRAIL_EXPECTED_EMAIL": "unrelated@example.com",
      ]
    )

    #expect(command.executableURL.path == "/opt/turnrail/codex")
    #expect(command.arguments == ["logout", "--config", "cli_auth_credentials_store=\"keyring\""])
    #expect(command.environment == ["CODEX_HOME": "/tmp/account/auth-home"])
  }
}
