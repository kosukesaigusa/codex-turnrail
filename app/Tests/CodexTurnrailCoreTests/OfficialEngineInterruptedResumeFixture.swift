import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterResumeOfficialEngineTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(2)))
  func signedEngineResumesAnInterruptedSession() throws {
    try OfficialEngineInterruptedResumeFixture.verify(
      app: URL(
        filePath: #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"])),
      router: URL(
        filePath: #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_ROUTER"])))
  }
}

enum OfficialEngineInterruptedResumeFixture {
  static func verify(app: URL, router: URL) throws {
    let installed = try OfficialEngineInstallation.verify(app: app)
    for existingHistory in [true, false] {
      try verify(installed: installed, router: router, existingHistory: existingHistory)
    }
  }

  private static func verify(
    installed: OfficialEngineInstallation, router: URL, existingHistory: Bool
  ) throws {
    let root = try RouterTestDirectory()
    let provider = try FixtureAccounts(root: root.url)
    let waiting = try WaitingModelServer(delay: nil)
    defer { waiting.stop() }
    let backend = FixtureModel()
    let home = root.url.appending(path: "home")
    try RouterJSON.privateDirectory(home)
    let auth = try RouterJSON.data(["OPENAI_API_KEY": "SYNTHETIC_RESUMED_SESSION_TEST"])
    let authFile = home.appending(path: "auth.json")
    try RouterJSON.writePrivate(auth, to: authFile)

    func startRuntime(storage: URL) throws -> RouterRuntime {
      let runtime = try RouterRuntime(
        root: storage, accounts: provider,
        connect: { account, _ in
          if account.account.id == provider.first.account.id {
            return waiting.connect(account: account.account.id)
          }
          return FixtureUpstream(account: account.account.id, backend: backend)
        })
      runtime.start()
      return runtime
    }
    func startEngine(_ runtime: RouterRuntime) throws -> OfficialEngineRPC {
      let overrides =
        try runtime.configuration(
          engine: installed.paths.launcher, home: home, executable: router) + [
          "cli_auth_credentials_store=\"file\"", "model=\"gpt-5.6-luna\"",
          "model_reasoning_effort=\"low\"", "features.apps=false", "features.plugins=false",
          "features.memories=false", "analytics.enabled=false", "web_search=\"disabled\"",
          "features.code_mode=true", "features.code_mode_host=true", "features.code_mode_only=true",
          "features.shell_tool=true", "approval_policy=\"never\"", "sandbox_mode=\"read-only\"",
        ]
      return try OfficialEngineRPC(
        engine: installed.paths.launcher, home: home, overrides: overrides, timeoutSeconds: 60)
    }

    var firstRuntime: RouterRuntime? = try startRuntime(storage: root.url)
    var firstRPC: OfficialEngineRPC? = try startEngine(#require(firstRuntime))
    let started = try #require(firstRPC).request(
      "thread/start", ["cwd": root.url.path, "ephemeral": false])
    let thread = try RouterJSON.text(RouterJSON.map(started, "thread"), "id")
    let first = try #require(firstRPC).request(
      "turn/start",
      [
        "threadId": thread,
        "input": [["type": "text", "text": "Wait for interruption.", "text_elements": []]],
      ])
    let firstTurn = try RouterJSON.text(RouterJSON.map(first, "turn"), "id")
    try #require(waiting.requestReceived.wait(timeout: .now() + 10) == .success)
    _ = try #require(firstRPC).request("turn/interrupt", ["threadId": thread, "turnId": firstTurn])
    let interrupted = try RouterJSON.map(#require(firstRPC).notification("turn/completed"), "turn")
    try #require(interrupted["status"] as? String == "interrupted")
    try #require(waiting.disconnected.wait(timeout: .now() + 10) == .success)
    #expect(
      try #require(firstRuntime).ledger.bound(thread + "/" + firstTurn) == provider.first.account.id
    )
    try #require(provider.selections == 1)
    firstRPC?.close()
    firstRPC = nil
    firstRuntime?.stop()
    firstRuntime = nil

    let storage = existingHistory ? root.url : root.url.appending(path: "fresh-router")
    let runtime = try startRuntime(storage: storage)
    defer { runtime.stop() }
    #expect(
      try runtime.ledger.bound(thread + "/" + firstTurn)
        == (existingHistory ? provider.first.account.id : nil))
    let rpc = try startEngine(runtime)
    defer { rpc.close() }
    let load: [String: Any] = ["threadId": thread]
    try runtime.observeRequest(["id": "load", "method": "thread/resume", "params": load])
    let loaded = try rpc.request("thread/resume", load)
    try runtime.observeResponse(["id": "load", "result": loaded])
    provider.choose(provider.second.account.id)
    let params: [String: Any] = [
      "threadId": thread, "turnTrigger": "resume_interrupted_task", "input": [Any](),
    ]
    try runtime.observeRequest(["id": "resume", "method": "turn/start", "params": params])
    backend.onNextRequest { provider.choose(provider.first.account.id) }
    let resumed = try rpc.request("turn/start", params)
    let resumedTurn = try RouterJSON.text(RouterJSON.map(resumed, "turn"), "id")
    try runtime.observeResponse(["id": "resume", "result": resumed])
    let result = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
    let details = try RouterJSON.string(result)
    try #require(result["status"] as? String == "completed", "\(details)")
    let calls = backend.requests(for: resumedTurn)
    try #require(calls.count == 2)
    #expect(calls.allSatisfy { $0.account == provider.second.account.id })
    #expect(
      try calls.allSatisfy {
        try RouterRequest.metadata($0.body.value)["turn_trigger"] as? String
          == "resume_interrupted_task"
      })
    #expect(try runtime.ledger.bound(thread + "/" + resumedTurn) == provider.second.account.id)
    #expect(provider.selections == 2)
    #expect(try Data(contentsOf: authFile) == auth)
  }
}
