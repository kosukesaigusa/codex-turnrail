import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterStartupPolicyTests {
  @Test
  func recognizesOnlyTheDedicatedDesktopInitialization() throws {
    let initialize = startupInitialization()
    #expect(RouterStartupPolicy.isInitialization(initialize))
    try RouterStartupPolicy.validate(initialize)
    for replacement in [
      ["id": 1], ["id": "initialize"], ["method": "turn/start"],
      ["params": ["clientInfo": ["name": "another-client"]]],
    ] as [[String: Any]] {
      let message = initialize.merging(replacement) { _, new in new }
      #expect(!RouterStartupPolicy.isInitialization(message))
      #expect(throws: RouterFailure.self) { try RouterStartupPolicy.validate(message) }
    }
  }

  @Test
  func policyConnectionCannotCreateTasksRunToolsOrChangeConfiguration() throws {
    try RouterStartupPolicy.validate(["method": "initialized"])
    for method in ["configRequirements/read", "config/read", "account/logout"] {
      try RouterStartupPolicy.validate(["id": "policy", "method": method, "params": [:]])
      #expect(throws: RouterFailure.self) {
        try RouterStartupPolicy.validate(["method": method, "params": [:]])
      }
    }
    for method in [
      "thread/start", "thread/resume", "thread/fork", "turn/start", "turn/steer",
      "command/exec", "config/value/write", "config/batchWrite", "account/login/start",
      "account/read", "account/rateLimits/read", "model/list", "unknown",
    ] {
      #expect(throws: RouterFailure.self) {
        try RouterStartupPolicy.validate(["id": "blocked", "method": method, "params": [:]])
      }
    }
    #expect(throws: RouterFailure.self) {
      try RouterStartupPolicy.validate(["id": "unsolicited", "result": [:]])
    }
  }

  @Test
  func initializationInspectionPreservesTheCompleteDesktopStartupSequence() throws {
    let pipe = Pipe()
    let messages = try [
      startupInitialization(), ["method": "initialized"],
      ["id": "network-requirements", "method": "configRequirements/read", "params": [:]],
      ["id": "network-config", "method": "config/read", "params": ["includeLayers": false]],
    ].map(RouterJSON.data)
    try pipe.fileHandleForWriting.write(
      contentsOf: messages.reduce(Data()) { $0 + $1 + Data([10]) })
    try pipe.fileHandleForWriting.close()
    let input = try RouterEngineInput(pipe.fileHandleForReading)
    #expect(input.hasInitialization)
    #expect(input.policyOnly)
    for message in messages {
      #expect(try input.next() == message)
      try RouterStartupPolicy.validate(RouterJSON.object(message))
    }
    #expect(try input.next() == nil)
  }
}

func startupInitialization() -> [String: Any] {
  [
    "id": "network-initialize", "method": "initialize",
    "params": [
      "clientInfo": ["name": "codex_desktop", "title": "Codex Desktop", "version": "1"],
      "capabilities": ["experimentalApi": true],
    ],
  ]
}
