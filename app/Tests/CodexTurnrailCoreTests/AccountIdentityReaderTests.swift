import Testing

@testable import CodexTurnrailCore

struct AccountIdentityReaderTests {
  @Test
  func buildsTheExactAccountReadHandshake() {
    #expect(AccountIdentityProtocol.initializeRequest.contains(#""id":1"#))
    #expect(AccountIdentityProtocol.initializeRequest.contains(#""method":"initialize""#))
    #expect(AccountIdentityProtocol.initializeRequest.contains(#""version":"0.5.0""#))
    #expect(AccountIdentityProtocol.initializedNotification == #"{"method":"initialized"}"#)
    #expect(
      AccountIdentityProtocol.accountReadRequest
        == #"{"id":2,"method":"account/read","params":{"refreshToken":false}}"#)
  }

  @Test
  func parsesAChatGPTAccountIdentity() throws {
    let identity = try AccountIdentityProtocol.parseAccountReadResponse(
      #"{"id":2,"result":{"account":{"type":"chatgpt","email":"PERSON@EXAMPLE.COM","planType":"plus"},"requiresOpenaiAuth":true}}"#
    )
    let expected = try ChatGPTAccountIdentity(
      email: "person@example.com",
      planType: .plus
    )

    #expect(identity == expected)
  }

  @Test
  func parsesALoggedOutAccount() throws {
    let identity = try AccountIdentityProtocol.parseAccountReadResponse(
      #"{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}"#
    )

    #expect(identity == nil)
  }

  @Test
  func rejectsAnAccountWithoutAnEmail() {
    #expect(throws: AccountReaderError.missingEmail) {
      try AccountIdentityProtocol.parseAccountReadResponse(
        #"{"id":2,"result":{"account":{"type":"chatgpt","email":null,"planType":"plus"},"requiresOpenaiAuth":true}}"#
      )
    }
  }

  @Test
  func rejectsAnUnsupportedPlan() {
    #expect(throws: AccountReaderError.unsupportedPlan("future-plan")) {
      try AccountIdentityProtocol.parseAccountReadResponse(
        #"{"id":2,"result":{"account":{"type":"chatgpt","email":"person@example.com","planType":"future-plan"},"requiresOpenaiAuth":true}}"#
      )
    }
  }

  @Test
  func preservesAnAppServerErrorForDiagnostics() {
    do {
      _ = try AccountIdentityProtocol.parseAccountReadResponse(
        #"{"id":2,"error":{"code":-32000,"message":"authentication failed"}}"#
      )
      Issue.record("Expected the account read to fail.")
    } catch AccountReaderError.serverError(let failure) {
      #expect(failure.message == "authentication failed")
      #expect(failure.diagnosticJSON.contains(#""code" : -32000"#))
      #expect(failure.recoveryAction == nil)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}
