import Darwin
import Foundation
import Testing

@testable import CodexTurnrailCore

struct RouterRecoveryTests {
  @Test
  func onlyKnownTemporaryTransportFailuresPermitEngineRecovery() {
    for phase in [RouterTransportFailure.Phase.check, .send, .receive] {
      for error in [
        URLError(.networkConnectionLost) as NSError,
        URLError(.timedOut) as NSError, NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTCONN)),
      ] {
        let failure = RouterTransportFailure(
          phase: phase, error: error, closeCode: .noStatusReceived)
        #expect(failure.permitsEngineRecovery)
      }
    }
    for error in [
      URLError(.cancelled) as NSError, URLError(.badServerResponse) as NSError,
      URLError(.serverCertificateUntrusted) as NSError,
      NSError(domain: "PRIVATE_UNKNOWN", code: 57),
    ] {
      #expect(
        !RouterTransportFailure(phase: .receive, error: error, closeCode: .invalid)
          .permitsEngineRecovery)
    }
    for close in [
      URLSessionWebSocketTask.CloseCode.protocolError, .policyViolation, .messageTooBig,
    ] {
      for error in [
        URLError(.networkConnectionLost) as NSError,
        NSError(domain: NSPOSIXErrorDomain, code: Int(ECANCELED)),
      ] {
        #expect(
          !RouterTransportFailure(
            phase: .receive, error: error, closeCode: close
          ).permitsEngineRecovery)
      }
    }
    var local = RouterTransportFailure(
      phase: .receive, error: URLError(.timedOut), closeCode: .invalid)
    local.cause = .localClose
    #expect(!local.permitsEngineRecovery)
  }

  @Test
  func onlyTransportReceiveCancellationPermitsEngineRecovery() {
    var failure = RouterTransportFailure(
      phase: .receive, error: NSError(domain: NSPOSIXErrorDomain, code: Int(ECANCELED)),
      closeCode: .invalid)
    #expect(failure.permitsEngineRecovery)
    for phase in [RouterTransportFailure.Phase.check, .send] {
      failure.phase = phase
      #expect(!failure.permitsEngineRecovery)
    }
    failure.phase = .receive
    for cause in [
      RouterTransportFailure.Cause.localClose, .probe, .keepAlive, .sendTimeout, .receiveTimeout,
    ] {
      failure.cause = cause
      #expect(!failure.permitsEngineRecovery)
    }
  }

  @Test
  func observedInterruptionAllowsEngineResubmissionButNeverActiveOrCompletedDuplicates() throws {
    let root = try RouterTestDirectory()
    let ledger = try RouterLedger(root: root.url)
    let account = UUID()
    try ledger.bind("thread/turn", account: account)
    #expect(throws: (any Error).self) { try ledger.interrupt("request", turn: "thread/turn") }
    for _ in 0..<3 {
      try ledger.begin("request", turn: "thread/turn")
      #expect(throws: (any Error).self) { try ledger.begin("request", turn: "thread/turn") }
      #expect(throws: (any Error).self) { try ledger.interrupt("request", turn: "other/turn") }
      try ledger.interrupt("request", turn: "thread/turn")
      #expect(try ledger.bound("thread/turn") == account)
      #expect(throws: (any Error).self) { try ledger.bind("thread/turn", account: UUID()) }
    }
    try ledger.begin("request", turn: "thread/turn")
    try ledger.finish("request", turn: "thread/turn")
    #expect(throws: (any Error).self) { try ledger.interrupt("request", turn: "thread/turn") }
    #expect(throws: (any Error).self) { try ledger.begin("request", turn: "thread/turn") }
  }

  @Test
  func interruptionsDoNotResetTheConnectionLimitAllowance() throws {
    let root = try RouterTestDirectory()
    let ledger = try RouterLedger(root: root.url)
    try ledger.bind("thread/turn", account: UUID())
    try ledger.begin("request", turn: "thread/turn")
    try ledger.interrupt("request", turn: "thread/turn")
    try ledger.begin("request", turn: "thread/turn")
    try ledger.rejectConnectionLimit("request", turn: "thread/turn")
    try ledger.begin("request", turn: "thread/turn")
    try ledger.interrupt("request", turn: "thread/turn")
    try ledger.begin("request", turn: "thread/turn")
    #expect(throws: (any Error).self) {
      try ledger.rejectConnectionLimit("request", turn: "thread/turn")
    }
  }

  @Test
  func engineCancellationRetainsBindingAcrossRestartButNeverPermitsTheSameInference() throws {
    let root = try RouterTestDirectory()
    let account = UUID()
    do {
      let ledger = try RouterLedger(root: root.url)
      try ledger.bind("parent/turn", account: account)
      #expect(throws: (any Error).self) { try ledger.cancel("missing", turn: "parent/turn") }
      try ledger.begin("cancelled", turn: "parent/turn")
      #expect(throws: (any Error).self) { try ledger.cancel("cancelled", turn: "other/turn") }
      try ledger.cancel("cancelled", turn: "parent/turn")
      #expect(throws: (any Error).self) { try ledger.begin("cancelled", turn: "parent/turn") }
      #expect(throws: (any Error).self) { try ledger.interrupt("cancelled", turn: "parent/turn") }
      #expect(throws: (any Error).self) {
        try ledger.rejectConnectionLimit("cancelled", turn: "parent/turn")
      }
    }
    let ledger = try RouterLedger(root: root.url)
    #expect(try ledger.bound("parent/turn") == account)
    #expect(throws: (any Error).self) { try ledger.begin("cancelled", turn: "parent/turn") }
    #expect(throws: (any Error).self) { try ledger.bind("parent/turn", account: UUID()) }
    try ledger.begin("changed-input", turn: "parent/turn")
    try ledger.finish("changed-input", turn: "parent/turn")
    try ledger.cancel("changed-input", turn: "parent/turn")
    #expect(throws: (any Error).self) { try ledger.begin("changed-input", turn: "parent/turn") }
    let child: [String: Any] = [
      "thread_id": "child", "turn_id": "child-turn", "thread_source": "subagent",
      "parent_thread_id": "parent", "parent_turn_id": "turn", "request_kind": "turn",
    ]
    #expect(try RouterRequest.binding(child, ledger: ledger).1 == account)
    try ledger.fail("parent/turn")
    #expect(throws: (any Error).self) { try RouterRequest.binding(child, ledger: ledger) }
  }

  @Test
  func restartDistinguishesRecordedInterruptionFromAnUncertainInFlightRequest() throws {
    let root = try RouterTestDirectory()
    let account = UUID()
    do {
      let ledger = try RouterLedger(root: root.url)
      try ledger.bind("thread/turn", account: account)
      try ledger.begin("request", turn: "thread/turn")
      try ledger.interrupt("request", turn: "thread/turn")
    }
    do {
      let ledger = try RouterLedger(root: root.url)
      #expect(try ledger.bound("thread/turn") == account)
      try ledger.begin("request", turn: "thread/turn")
    }
    let ledger = try RouterLedger(root: root.url)
    #expect(throws: (any Error).self) { try ledger.bound("thread/turn") }
  }
}
