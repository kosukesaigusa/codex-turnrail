import Darwin
import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterBoundaryTests {
  @Test
  func authenticationMustMatchEmailWorkspaceAndExpiry() throws {
    let now = Date(timeIntervalSince1970: 1000)
    let good = try authentication(
      email: "owner@example.com", workspace: "work", accessWorkspace: "work", expiry: 2000)
    #expect(
      try AccountCredentialStore.validate(good, expectedEmail: "OWNER@example.com", now: now)
        .accountID == "work")
    #expect(throws: (any Error).self) {
      try AccountCredentialStore.validate(good, expectedEmail: "another@example.com", now: now)
    }
    #expect(throws: (any Error).self) {
      try AccountCredentialStore.validate(
        good, expectedEmail: "owner@example.com", now: Date(timeIntervalSince1970: 2000))
    }
    let crossed = try authentication(
      email: "owner@example.com", workspace: "work", accessWorkspace: "personal", expiry: 2000)
    #expect(throws: (any Error).self) {
      try AccountCredentialStore.validate(crossed, expectedEmail: "owner@example.com", now: now)
    }
  }

  @Test
  func nestedRoutingOverridesAndBatchWritesAreRejectedButTitleHooksAreAllowed() throws {
    let observer = RouterEngineObserver()
    for params: [String: Any] in [
      ["config": ["features": ["hooks": false]]],
      ["config": ["model_providers": ["openai": ["base_url": "https://unbound.invalid"]]]],
      ["modelProvider": "another-provider"],
    ] {
      #expect(throws: (any Error).self) {
        try observer.request(["id": UUID().uuidString, "method": "thread/start", "params": params])
      }
    }
    #expect(throws: (any Error).self) {
      try observer.request([
        "id": "write", "method": "config/batchWrite",
        "params": ["edits": [["keyPath": "features", "value": ["hooks": false]]]],
      ])
    }
    for edit: [String: Any] in [
      ["keyPath": "features", "value": ["hooks": false], "mergeStrategy": "upsert"],
      ["keyPath": "features", "value": [:], "mergeStrategy": "replace"],
    ] {
      #expect(throws: (any Error).self) {
        try observer.request(["id": "write", "method": "config/value/write", "params": edit])
      }
    }
    try observer.request([
      "id": "title", "method": "thread/start",
      "params": ["threadSource": "thread_title", "config": ["features.hooks": false]],
    ])
  }

  @Test
  func quotedConfigurationPathsCannotDisableRouting() throws {
    let observer = RouterEngineObserver()
    for path in [#""features"."hooks""#, #""openai_base_url""#, #""features".remote_models"#] {
      #expect(throws: (any Error).self) {
        try observer.request([
          "id": path, "method": "config/value/write",
          "params": ["keyPath": path, "value": false, "mergeStrategy": "replace"],
        ])
      }
    }
    try observer.request([
      "id": "plugin", "method": "config/value/write",
      "params": [
        "keyPath": #"plugins."example@catalog".enabled"#, "value": true,
        "mergeStrategy": "replace",
      ],
    ])
  }

  @Test
  func modelIntersectionDoesNotAdvertiseAnotherAccountsCapabilities() throws {
    let first: [String: Any] = [
      "slug": "shared", "supported_reasoning_levels": [["effort": "low"], ["effort": "high"]],
      "default_reasoning_level": "high", "input_modalities": ["text", "image"],
      "service_tiers": [["id": "priority"]], "default_service_tier": "priority",
      "context_window": 200000, "multi_agent_version": "v1",
    ]
    var other = first
    other["supported_reasoning_levels"] = [["effort": "low"]]
    other["input_modalities"] = ["text"]
    other["service_tiers"] = [[String: Any]]()
    other["context_window"] = 100000
    let common = try RouterModelCatalog.intersection([[first], [other]])
    #expect(common.count == 1)
    #expect(common[0]["default_reasoning_level"] as? String == "low")
    #expect(common[0]["default_service_tier"] == nil)
    #expect(common[0]["context_window"] as? Int == 100000)
    #expect(common[0]["input_modalities"] as? [String] == ["text"])
    #expect(throws: (any Error).self) {
      try RouterModelCatalog.validate(
        ["model": "shared", "reasoning": ["effort": "high"]], catalog: [other])
    }
    other["multi_agent_version"] = "v2"
    #expect(throws: (any Error).self) { try RouterModelCatalog.intersection([[first], [other]]) }
  }

  @Test
  func incompleteModelCapabilitiesCannotBeInheritedFromAnotherAccount() throws {
    let first: [String: Any] = [
      "slug": "shared", "context_window": 100000, "supports_search_tool": true,
    ]
    for field in ["context_window", "supports_search_tool"] {
      var incomplete = first
      incomplete.removeValue(forKey: field)
      #expect(throws: (any Error).self) {
        try RouterModelCatalog.intersection([[first], [incomplete]])
      }
      #expect(throws: (any Error).self) {
        try RouterModelCatalog.intersection([[incomplete], [first]])
      }
    }
  }

  @Test
  func persistedDeltaHistoryReconstructsAfterRestartAndDetectsCorruption() throws {
    let root = try RouterTestDirectory()
    let first: [[String: Any]] = [["type": "message", "content": "original"]]
    let answer: [[String: Any]] = [["type": "message", "content": "answer"]]
    do {
      let ledger = try RouterLedger(root: root.url)
      try ledger.saveHistory(
        id: "first", value: ["thread": "task", "input": first, "output": answer])
      try ledger.saveHistory(
        id: "next",
        value: ["thread": "task", "previous": "first", "input": first, "output": answer])
      let files = try FileManager.default.contentsOfDirectory(
        atPath: root.url.appending(path: "messages").path)
      #expect(files.count == 2)
    }
    let ledger = try RouterLedger(root: root.url)
    #expect(try RouterJSON.array(ledger.history("next", thread: "task"), "input").count == 3)
    let file = root.url.appending(
      path: "messages/" + RouterJSON.hash(try RouterJSON.data(first[0])) + ".json")
    try Data("{}".utf8).write(to: file)
    #expect(throws: (any Error).self) { try ledger.history("next", thread: "task") }
  }

  @Test
  func webSocketHandlesFragmentedMaskedJSONAndRejectsUnmaskedClients() throws {
    let pair = try SocketPair()
    try pair.client.write(
      Data([0x01, 0x81, 1, 2, 3, 4, 0x7b ^ 1, 0x80, 0x81, 1, 2, 3, 4, 0x7d ^ 1]))
    #expect(try pair.server.message() == Data("{}".utf8))
    try pair.client.write(Data([0x81, 0x02, 0x7b, 0x7d]))
    #expect(throws: (any Error).self) { try pair.server.message() }
  }

  @Test
  func webOriginsAndAmbiguousHttpHeadersCannotReachTheRouter() throws {
    for headers in [
      "Origin: https://website.invalid\r\n", "Content-Length: 2\r\nContent-Length: 4\r\n",
      "Transfer-Encoding: chunked\r\n",
    ] {
      let pair = try SocketPair()
      try pair.client.write(
        Data("POST /secret/hook HTTP/1.1\r\nHost: 127.0.0.1\r\n\(headers)\r\n".utf8))
      #expect(throws: (any Error).self) { try pair.server.request() }
    }
  }

  private func authentication(
    email: String, workspace: String, accessWorkspace: String, expiry: Int
  ) throws -> Data {
    func token(_ claims: [String: Any]) throws -> String {
      "header."
        + (try RouterJSON.data(claims)).base64EncodedString().replacingOccurrences(
          of: "+", with: "-"
        ).replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        + ".signature"
    }
    return try RouterJSON.data([
      "tokens": [
        "account_id": workspace,
        "access_token": token([
          "exp": expiry, "https://api.openai.com/auth": ["chatgpt_account_id": accessWorkspace],
        ]),
        "id_token": token([
          "email": email, "https://api.openai.com/auth": ["chatgpt_account_id": workspace],
        ]),
      ]
    ])
  }
}

private final class SocketPair {
  let server: RouterSocket
  let client: RouterSocket
  init() throws {
    var pair: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
      throw RouterFailure("Could not create test socket pair.")
    }
    server = RouterSocket(pair[0])
    client = RouterSocket(pair[1])
  }
  deinit {
    server.close()
    client.close()
  }
}
