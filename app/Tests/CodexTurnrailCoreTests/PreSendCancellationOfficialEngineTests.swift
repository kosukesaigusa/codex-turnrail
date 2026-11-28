import Darwin
import Foundation
import Testing

@testable import CodexTurnrailCore

extension RouterOfficialEngineTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(2)))
  func preSendCancellationRecoversWithoutReplayingARequest() throws {
    let installed = try OfficialEngineInstallation.verify(
      app: URL(
        filePath: #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"]))
    )
    let router = URL(
      filePath: try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_ROUTER"]))
    for scenario in [SendCancellationScenario.beforeSend, .duringSend, .localClose] {
      let root = try RouterTestDirectory()
      let provider = try FixtureAccounts(root: root.url)
      let backend = FixtureModel()
      let cancellation = SendCancellationFixture(scenario: scenario, provider: provider)
      let runtime = try RouterRuntime(
        root: root.url, accounts: provider,
        connect: { account, _ in
          SendCancellationUpstream(
            account: account.account.id, backend: backend, cancellation: cancellation)
        })
      runtime.start()
      defer { runtime.stop() }
      let home = root.url.appending(path: "home")
      try RouterJSON.privateDirectory(home)
      let authFile = home.appending(path: "auth.json")
      let auth = try RouterJSON.data(["OPENAI_API_KEY": "SYNTHETIC_PRESEND_CANCELLATION"])
      try RouterJSON.writePrivate(auth, to: authFile)
      let overrides =
        try runtime.configuration(engine: installed.paths.launcher, home: home, executable: router)
        + [
          "cli_auth_credentials_store=\"file\"", "model=\"gpt-5.6-luna\"",
          "model_reasoning_effort=\"low\"", "features.apps=false", "features.plugins=false",
          "features.memories=false", "analytics.enabled=false", "web_search=\"disabled\"",
          "features.code_mode=true", "features.code_mode_host=true", "features.code_mode_only=true",
          "features.shell_tool=true", "approval_policy=\"never\"",
          "sandbox_mode=\"workspace-write\"", "features.unbounded_connection_retries=false",
        ]
      let rpc = try OfficialEngineRPC(
        engine: installed.paths.launcher, home: home, overrides: overrides, timeoutSeconds: 60)
      defer { rpc.close() }
      let marker = root.url.appending(path: "presend-marker.txt")
      let command: [String: Any] = [
        "cmd": "printf 'executed\\n' >> " + RouterJSON.shellQuote(marker.path)
          + "; printf PRESEND_COMPLETED_TOOL_RESULT",
        "login": false, "yield_time_ms": 10000,
      ]
      backend.setTool("text(await tools.exec_command(" + (try RouterJSON.string(command)) + "));")
      let thread = try RouterJSON.text(
        RouterJSON.map(
          rpc.request(
            "thread/start",
            [
              "cwd": root.url.path, "ephemeral": true, "approvalPolicy": "never",
              "sandbox": "workspace-write",
            ]), "thread"), "id")
      let started = try rpc.request(
        "turn/start",
        [
          "threadId": thread,
          "input": [["type": "text", "text": "Run the marker once.", "text_elements": []]],
        ])
      let turn = try RouterJSON.text(RouterJSON.map(started, "turn"), "id")
      let done = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
      let calls = backend.requests(for: turn)
      #expect(calls.allSatisfy { $0.account == provider.first.account.id })
      #expect(try String(contentsOf: marker, encoding: .utf8) == "executed\n")
      if scenario == .beforeSend {
        try #require(done["status"] as? String == "completed", "\(done)")
        #expect(calls.count == 2)
        let input = try RouterJSON.array(#require(calls.last).body.value, "input")
        #expect(try RouterJSON.string(input).contains("PRESEND_COMPLETED_TOOL_RESULT"))
        #expect(try runtime.ledger.bound(thread + "/" + turn) == provider.first.account.id)
      } else {
        #expect(done["status"] as? String == "failed")
        #expect(calls.count == (scenario == .duringSend ? 2 : 1))
        #expect(throws: (any Error).self) { try runtime.ledger.bound(thread + "/" + turn) }
      }
      #expect(cancellation.attempts == (scenario == .beforeSend ? 3 : 2))
      let diagnostic = try #require(
        RouterJSON.array(
          RouterJSON.object(
            Data(contentsOf: root.url.appending(path: "router/transport-diagnostics.json"))),
          "entries"
        ).last)
      #expect(diagnostic["code"] as? Int == Int(ECANCELED))
      #expect(diagnostic["phase"] as? String == (scenario == .duringSend ? "send" : "check"))
      #expect(try RouterJSON.map(diagnostic, "request")["receivedEvents"] as? Int == 0)
      #expect(try Data(contentsOf: authFile) == auth)
    }
  }
}

private enum SendCancellationScenario: Sendable {
  case beforeSend, duringSend, localClose
}

private final class SendCancellationFixture: @unchecked Sendable {
  let scenario: SendCancellationScenario
  let provider: FixtureAccounts
  private let lock = NSLock()
  private var count = 0
  var attempts: Int { lock.withLock { count } }

  init(scenario: SendCancellationScenario, provider: FixtureAccounts) {
    self.scenario = scenario
    self.provider = provider
  }

  func interruptNextSend() -> Bool {
    lock.withLock {
      count += 1
      return count == 2
    }
  }
}

/// Fail before submission, after possible submission, or after a deliberate close.
private final class SendCancellationUpstream: RouterUpstream, @unchecked Sendable {
  private let upstream: FixtureUpstream
  private let cancellation: SendCancellationFixture
  var generation: String { upstream.generation }
  var accountID: UUID { upstream.accountID }

  init(account: UUID, backend: FixtureModel, cancellation: SendCancellationFixture) {
    upstream = FixtureUpstream(account: account, backend: backend)
    self.cancellation = cancellation
  }

  func checkConnection() throws { try upstream.checkConnection() }
  func receive() throws -> Data { try upstream.receive() }
  func close() { upstream.close() }

  func send(_ data: Data) throws {
    guard cancellation.interruptNextSend() else { return try upstream.send(data) }
    cancellation.provider.choose(cancellation.provider.second.account.id)
    if cancellation.scenario == .duringSend { try upstream.send(data) }
    var failure = RouterTransportFailure(
      phase: cancellation.scenario == .duringSend ? .send : .check,
      error: NSError(domain: NSPOSIXErrorDomain, code: Int(ECANCELED)), closeCode: .invalid)
    if cancellation.scenario == .localClose { failure.cause = .localClose }
    throw failure
  }
}
