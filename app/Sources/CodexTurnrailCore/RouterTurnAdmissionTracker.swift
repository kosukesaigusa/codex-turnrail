import Foundation

enum RouterAdmittedTurnTrigger: String {
  case interruptedResume = "resume_interrupted_task"
  case scheduledHeartbeat = "automation_heartbeat_scheduled"
  case immediateHeartbeat = "automation_heartbeat_run_now"
  case scheduledAutomation = "automation_cron_scheduled"
  case immediateAutomation = "automation_cron_run_now"
}

/// Correlates desktop turn requests with the Engine's confirmed turn and directory.
final class RouterTurnAdmissionTracker: @unchecked Sendable {
  enum ClaimSource {
    case model(RouterAdmittedTurnTrigger)
    case compactHook
  }

  private struct Admission {
    let request: String
    let cwd: String
    let trigger: RouterAdmittedTurnTrigger
    var expectedTurn: String?
    var finishedTurns: Set<String> = []
  }

  private let condition = NSCondition()
  private var directories: [String: String] = [:]
  private var loads: Set<String> = []
  private var admissions: [String: Admission] = [:]

  static func trigger(_ params: [String: Any]) -> RouterAdmittedTurnTrigger? {
    guard let value = params["turnTrigger"] as? String,
      let trigger = RouterAdmittedTurnTrigger(rawValue: value),
      let input = params["input"] as? [Any], input.isEmpty
    else { return nil }
    switch trigger {
    case .interruptedResume:
      guard params["toolOutput"] == nil || params["toolOutput"] is NSNull else { return nil }
    case .scheduledHeartbeat, .immediateHeartbeat, .scheduledAutomation, .immediateAutomation:
      guard let output = params["toolOutput"] as? [String: Any],
        output["name"] as? String == "automation_update",
        output["namespace"] as? String == "codex_app"
      else { return nil }
    }
    return trigger
  }

  func remember(thread: String, cwd: String) {
    condition.withLock { directories[thread] = cwd }
  }

  func request(_ message: [String: Any]) throws {
    guard let method = message["method"] as? String,
      let params = message["params"] as? [String: Any]
    else { return }
    if ["thread/start", "thread/resume", "thread/fork"].contains(method) {
      let id = try Self.id(message)
      try condition.withLock {
        guard !admissions.values.contains(where: { $0.request == id }), loads.insert(id).inserted
        else {
          throw RouterFailure("Duplicate pending thread request.")
        }
      }
      return
    }
    guard method == "turn/start", let trigger = Self.trigger(params) else { return }
    let thread = try RouterJSON.text(params, "threadId")
    let request = try Self.id(message)
    let cwd: String
    if let override = params["cwd"], !(override is NSNull) {
      guard let path = override as? String else { throw RouterFailure("Invalid turn directory.") }
      cwd = try RouterDirectory.canonical(path).path
    } else {
      let directory = try condition.withLock {
        guard let directory = directories[thread] else {
          throw RouterFailure("The turn requires the loaded thread's working directory.")
        }
        return directory
      }
      cwd = try RouterDirectory.canonical(directory).path
    }
    try condition.withLock {
      guard admissions[thread] == nil, !loads.contains(request),
        !admissions.values.contains(where: { $0.request == request })
      else {
        throw RouterFailure("A turn request is already pending for this thread.")
      }
      admissions[thread] = Admission(request: request, cwd: cwd, trigger: trigger)
    }
  }

  func response(_ message: [String: Any]) throws {
    if message["method"] as? String == "turn/completed",
      let params = message["params"] as? [String: Any],
      let thread = params["threadId"] as? String,
      let turn = (params["turn"] as? [String: Any])?["id"] as? String
    {
      condition.withLock {
        guard var admission = admissions[thread] else { return }
        if admission.expectedTurn == turn {
          admissions.removeValue(forKey: thread)
        } else if admission.expectedTurn == nil {
          admission.finishedTurns.insert(turn)
          admissions[thread] = admission
        }
        condition.broadcast()
      }
      return
    }
    guard message["method"] == nil, message["id"] != nil else { return }
    let request = try Self.id(message)
    let isLoad = condition.withLock { loads.remove(request) != nil }
    if isLoad, message["error"] == nil,
      let result = message["result"] as? [String: Any],
      let thread = result["thread"] as? [String: Any],
      let id = thread["id"] as? String, !id.isEmpty,
      let cwd = thread["cwd"] as? String, !cwd.isEmpty
    {
      remember(thread: id, cwd: cwd)
    }
    try condition.withLock {
      guard let thread = admissions.first(where: { $0.value.request == request })?.key,
        var admission = admissions[thread]
      else { return }
      guard message["error"] == nil else {
        admissions.removeValue(forKey: thread)
        condition.broadcast()
        return
      }
      do {
        let turn = try RouterJSON.text(
          RouterJSON.map(RouterJSON.map(message, "result"), "turn"), "id")
        directories[thread] = admission.cwd
        admission.expectedTurn = turn
        if admission.finishedTurns.contains(turn) {
          admissions.removeValue(forKey: thread)
        } else {
          admissions[thread] = admission
        }
        condition.broadcast()
      } catch {
        admissions.removeValue(forKey: thread)
        condition.broadcast()
        throw error
      }
    }
  }

  /// Claim an admitted turn from its model metadata or its compact hook.
  func claim(thread: String, turn: String, source: ClaimSource) throws -> String? {
    try condition.withLock {
      guard admissions[thread] != nil else { return nil }
      let deadline = Date().addingTimeInterval(10)
      while let admission = admissions[thread], admission.expectedTurn == nil {
        guard condition.wait(until: deadline) else {
          throw RouterFailure("The Engine did not confirm the turn in time.")
        }
      }
      guard let admission = admissions[thread] else {
        throw RouterFailure("The Engine did not accept the pending turn.")
      }
      if let expected = admission.expectedTurn, expected != turn { return nil }
      if case .model(let trigger) = source, trigger != admission.trigger {
        throw RouterFailure("The model request does not match the admitted turn trigger.")
      }
      guard !admission.finishedTurns.contains(turn) else {
        throw RouterFailure("The admitted turn has already ended.")
      }
      admissions.removeValue(forKey: thread)
      return admission.cwd
    }
  }

  private static func id(_ message: [String: Any]) throws -> String {
    if let id = message["id"] as? String { return "s:" + id }
    if let id = message["id"] as? Int { return "n:\(id)" }
    throw RouterFailure("Invalid Engine protocol request ID.")
  }
}
