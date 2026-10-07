import Darwin
import Foundation
import Testing

@testable import CodexTurnrailCore

extension RouterOfficialEngineTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"] != nil),
    .timeLimit(.minutes(2)))
  func remoteReceiveCancellationRecoversOnTheBoundAccountWhileLocalCancellationStops() throws {
    let installed = try OfficialEngineInstallation.verify(
      app: URL(
        filePath: #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_OFFICIAL_APP"]))
    )
    let router = URL(
      filePath: try #require(ProcessInfo.processInfo.environment["CODEX_TURNRAIL_TEST_ROUTER"]))
    for cause in [RouterTransportFailure.Cause.transport, .localClose] {
      let root = try RouterTestDirectory()
      let provider = try FixtureAccounts(root: root.url)
      let backend = FixtureModel()
      let runtime = try RouterRuntime(
        root: root.url, accounts: provider,
        connect: { account, _ in
          ReceiveCancellationUpstream(account: account.account.id, backend: backend, cause: cause)
        })
      runtime.start()
      defer { runtime.stop() }
      let home = root.url.appending(path: "home")
      try RouterJSON.privateDirectory(home)
      let authFile = home.appending(path: "auth.json")
      let auth = try RouterJSON.data(["OPENAI_API_KEY": "SYNTHETIC_RECEIVE_CANCELLATION"])
      try RouterJSON.writePrivate(auth, to: authFile)
      let overrides =
        try runtime.configuration(engine: installed.paths.launcher, home: home, executable: router)
        + [
          "cli_auth_credentials_store=\"file\"", "model=\"gpt-5.6-luna\"",
          "model_reasoning_effort=\"low\"",
          "features.apps=false", "features.plugins=false", "features.memories=false",
          "analytics.enabled=false", "web_search=\"disabled\"",
          "features.code_mode=true", "features.code_mode_host=true", "features.code_mode_only=true",
          "features.shell_tool=true", "approval_policy=\"never\"",
          "sandbox_mode=\"workspace-write\"",
          "features.unbounded_connection_retries=false",
        ]
      let rpc = try OfficialEngineRPC(
        engine: installed.paths.launcher, home: home, overrides: overrides, timeoutSeconds: 60)
      defer { rpc.close() }
      let marker = root.url.appending(path: "receive-cancellation-tool.txt")
      let command: [String: Any] = [
        "cmd": "printf 'executed\\n' >> " + RouterJSON.shellQuote(marker.path)
          + "; printf RECEIVE_CANCELLATION_TOOL_RESULT",
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
      provider.choose(provider.first.account.id)
      // Remote cancellation follows a completed tool result. Local cancellation stops
      // immediately after response creation, before any tool can execute.
      backend.interrupt(after: cause == .transport ? 1 : 0, count: 1, at: .created) {
        provider.choose(provider.second.account.id)
      }
      let start = try rpc.request(
        "turn/start",
        [
          "threadId": thread,
          "input": [["type": "text", "text": "Run the marker once.", "text_elements": []]],
        ])
      let turn = try RouterJSON.text(RouterJSON.map(start, "turn"), "id")
      let done = try RouterJSON.map(rpc.notification("turn/completed"), "turn")
      let calls = backend.requests(for: turn)
      #expect(calls.allSatisfy { $0.account == provider.first.account.id })
      #expect(calls.allSatisfy { $0.transport == "websocket" })
      if cause == .transport {
        try #require(done["status"] as? String == "completed", "\(done)")
        #expect(calls.count == 3)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "executed\n")
        let input = try RouterJSON.array(#require(calls.last).body.value, "input")
        #expect(try RouterJSON.string(input).contains("RECEIVE_CANCELLATION_TOOL_RESULT"))
        #expect(try runtime.ledger.bound(thread + "/" + turn) == provider.first.account.id)
      } else {
        #expect(done["status"] as? String == "failed")
        #expect(calls.count == 1)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(throws: (any Error).self) { try runtime.ledger.bound(thread + "/" + turn) }
      }
      let diagnostic = try #require(
        RouterJSON.array(
          RouterJSON.object(
            Data(contentsOf: root.url.appending(path: "router/transport-diagnostics.json"))),
          "entries"
        ).last)
      #expect(diagnostic["code"] as? Int == Int(ECANCELED))
      #expect(diagnostic["phase"] as? String == "receive")
      #expect(diagnostic["cause"] as? String == cause.rawValue)
      #expect(try RouterJSON.map(diagnostic, "request")["responseStarted"] as? Bool == true)
      #expect(try Data(contentsOf: authFile) == auth)
    }
  }
}

/// Inject the recorded Foundation receive error into an interrupted synthetic stream.
private final class ReceiveCancellationUpstream: RouterUpstream, @unchecked Sendable {
  private let upstream: FixtureUpstream
  private let cause: RouterTransportFailure.Cause
  var generation: String { upstream.generation }
  var accountID: UUID { upstream.accountID }

  init(account: UUID, backend: FixtureModel, cause: RouterTransportFailure.Cause) {
    upstream = FixtureUpstream(account: account, backend: backend)
    self.cause = cause
  }

  func checkConnection() throws { try upstream.checkConnection() }
  func send(_ data: Data) throws { try upstream.send(data) }
  func close() { upstream.close() }

  func receive() throws -> Data {
    do { return try upstream.receive() } catch let error as RouterTransportFailure {
      guard error.phase == .receive, error.domain == NSURLErrorDomain,
        error.code == URLError.networkConnectionLost.rawValue
      else { throw error }
      var failure = RouterTransportFailure(
        phase: .receive, error: NSError(domain: NSPOSIXErrorDomain, code: Int(ECANCELED)),
        closeCode: .invalid)
      failure.cause = cause
      throw failure
    }
  }
}
