import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterInspectionFailureTests {
  @Test
  func metadataTransportErrorsIdentifyTheOperationWithoutReflectingTheURL() throws {
    for (path, operation) in [
      ("/backend-api/wham/usage", "usage"), ("/backend-api/codex/models", "model catalog"),
    ] {
      let url = try #require(URL(string: "invalid-fixture://host\(path)?token=SECRET"))
      do {
        _ = try RouterHTTP().get(
          url,
          credential: RouterCredential(
            accessToken: "SECRET", accountID: "SECRET_WORKSPACE", expiresAt: .distantFuture))
        Issue.record("Unsupported scheme unexpectedly succeeded.")
      } catch {
        let text = error.localizedDescription
        #expect(text.contains("Account \(operation) inspection:"))
        #expect(text.contains(NSURLErrorDomain))
        #expect(!text.contains("SECRET"))
        #expect(!text.contains("invalid-fixture:"))
      }
    }
  }

  @Test
  func transportDiagnosticsExposeOnlyKnownNumericCodes() {
    for domain in [NSURLErrorDomain, NSPOSIXErrorDomain, "SECRET_DOMAIN"] {
      let error = NSError(
        domain: domain, code: -1001,
        userInfo: [NSLocalizedDescriptionKey: "SECRET https://private.invalid/?token=SECRET"])
      let text = RouterInspectionFailure.transport(error).localizedDescription
      #expect(!text.contains("SECRET"))
      #expect(!text.contains("https://"))
      if domain == "SECRET_DOMAIN" {
        #expect(text.contains("transport cause unavailable"))
      } else {
        #expect(text.contains("\(domain): -1001"))
      }
    }
  }

  @Test
  func rpcDiagnosticsClassifyOnlyExactKnownMessagesAndIntegerCodes() {
    let cases: [(String, String)] = [
      ("workspace routing discovery timed out", "workspace routing timeout"),
      ("workspace routing discovery failed", "workspace routing unavailable"),
      ("workspace routing discovery failed: SECRET", "cause unavailable"),
      ("SECRET email@example.com token https://private.invalid", "cause unavailable"),
    ]
    for (message, reason) in cases {
      let text = RouterInspectionFailure.rpc(
        method: "account/read",
        error: ["code": -32603, "message": message, "data": ["token": "SECRET"]]
      ).localizedDescription
      #expect(text.contains("account/read"))
      #expect(text.contains("RPC: -32603"))
      #expect(text.contains(reason))
      #expect(!text.contains("SECRET"))
      #expect(!text.contains("email@example.com"))
    }
    for code: Any in [true, 0.5, "SECRET", NSNull()] {
      let text = RouterInspectionFailure.rpc(method: "account/read", error: ["code": code])
        .localizedDescription
      #expect(!text.contains("RPC:"))
      #expect(!text.contains("SECRET"))
      #expect(text.contains("cause unavailable"))
    }
  }
}
