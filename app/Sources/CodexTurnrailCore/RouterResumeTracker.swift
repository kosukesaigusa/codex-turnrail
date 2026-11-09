import Foundation

/// Correlates explicit desktop resume requests with the Engine's new turn.
final class RouterResumeTracker: @unchecked Sendable {
  private struct Admission {
    let request: String
    let cwd: String
    var expectedTurn: String?
    var finishedTurns: Set<String> = []
  }

  private let condition = NSCondition()
  private var directories: [String: String] = [:]
  private var loads: Set<String> = []
  private var resumes: [String: Admission] = [:]

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
        guard !resumes.values.contains(where: { $0.request == id }), loads.insert(id).inserted
        else {
          throw RouterFailure("Duplicate pending thread request.")
        }
      }
      return
    }
    guard method == "turn/start", params["turnTrigger"] as? String == "resume_interrupted_task",
      let input = params["input"] as? [Any], input.isEmpty,
      params["toolOutput"] == nil || params["toolOutput"] is NSNull
    else { return }
    let thread = try RouterJSON.text(params, "threadId")
    let request = try Self.id(message)
    let cwd: String
    if let override = params["cwd"], !(override is NSNull) {
      guard let path = override as? String else { throw RouterFailure("Invalid resume directory.") }
      cwd = try RouterDirectory.canonical(path).path
    } else {
      let directory = try condition.withLock {
        guard let directory = directories[thread] else {
          throw RouterFailure("Resume requires the loaded thread's working directory.")
        }
        return directory
      }
      cwd = try RouterDirectory.canonical(directory).path
    }
    try condition.withLock {
      guard resumes[thread] == nil, !loads.contains(request),
        !resumes.values.contains(where: { $0.request == request })
      else {
        throw RouterFailure("A resume request is already pending for this thread.")
      }
      resumes[thread] = Admission(request: request, cwd: cwd)
    }
  }

  func response(_ message: [String: Any]) throws {
    if message["method"] as? String == "turn/completed",
      let params = message["params"] as? [String: Any],
      let thread = params["threadId"] as? String,
      let turn = (params["turn"] as? [String: Any])?["id"] as? String
    {
      condition.withLock {
        guard var admission = resumes[thread] else { return }
        if admission.expectedTurn == turn {
          resumes.removeValue(forKey: thread)
        } else if admission.expectedTurn == nil {
          admission.finishedTurns.insert(turn)
          resumes[thread] = admission
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
      guard let thread = resumes.first(where: { $0.value.request == request })?.key,
        var admission = resumes[thread]
      else { return }
      guard message["error"] == nil else {
        resumes.removeValue(forKey: thread)
        condition.broadcast()
        return
      }
      do {
        let turn = try RouterJSON.text(
          RouterJSON.map(RouterJSON.map(message, "result"), "turn"), "id")
        directories[thread] = admission.cwd
        admission.expectedTurn = turn
        if admission.finishedTurns.contains(turn) {
          resumes.removeValue(forKey: thread)
        } else {
          resumes[thread] = admission
        }
        condition.broadcast()
      } catch {
        resumes.removeValue(forKey: thread)
        condition.broadcast()
        throw error
      }
    }
  }

  /// Claim an admitted resume from its model metadata, or from its compact hook.
  func claim(thread: String, turn: String) throws -> String? {
    try condition.withLock {
      guard resumes[thread] != nil else { return nil }
      let deadline = Date().addingTimeInterval(10)
      while let admission = resumes[thread], admission.expectedTurn == nil {
        guard condition.wait(until: deadline) else {
          throw RouterFailure("The Engine did not confirm the resumed turn in time.")
        }
      }
      guard let admission = resumes[thread] else {
        throw RouterFailure("The Engine did not accept the pending resume.")
      }
      if let expected = admission.expectedTurn, expected != turn { return nil }
      guard !admission.finishedTurns.contains(turn) else {
        throw RouterFailure("The resumed turn has already ended.")
      }
      resumes.removeValue(forKey: thread)
      return admission.cwd
    }
  }

  private static func id(_ message: [String: Any]) throws -> String {
    if let id = message["id"] as? String { return "s:" + id }
    if let id = message["id"] as? Int { return "n:\(id)" }
    throw RouterFailure("Invalid Engine protocol request ID.")
  }
}
