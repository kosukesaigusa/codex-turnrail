import Darwin
import Foundation

/// Serializes account bindings and delivery decisions before network side effects.
final class RouterLedger: @unchecked Sendable {
  private let lock = NSRecursiveLock()
  private let file: URL
  private let messagesDirectory: URL
  private var state: [String: Any]
  private let ownerLock: Int32

  init(root: URL) throws {
    try RouterJSON.privateDirectory(root)
    file = root.appending(path: "ledger.json")
    messagesDirectory = root.appending(path: "messages")
    try RouterJSON.privateDirectory(messagesDirectory)
    let lockPath = root.appending(path: "owner.lock")
    ownerLock = open(lockPath.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard ownerLock >= 0, flock(ownerLock, LOCK_EX | LOCK_NB) == 0 else {
      if ownerLock >= 0 { close(ownerLock) }
      throw RouterFailure("Another Turnrail routing process is running.")
    }
    do {
      if FileManager.default.fileExists(atPath: file.path) {
        state = try RouterJSON.object(Data(contentsOf: file))
        guard state["schemaVersion"] as? Int == 1 else {
          throw RouterFailure("Unsupported routing ledger schema.")
        }
        for key in ["bindings", "titles", "completed", "history", "requests", "failed"] {
          _ = try RouterJSON.map(state, key)
        }
        var failed = try RouterJSON.map(state, "failed")
        for case let request as [String: Any] in try RouterJSON.map(state, "requests").values {
          if ["forwarding", "retrying"].contains(request["state"] as? String) {
            failed[try RouterJSON.text(request, "turn")] = true
          }
        }
        state["failed"] = failed
      } else {
        state = [
          "schemaVersion": 1, "bindings": [String: Any](), "titles": [String: Any](),
          "completed": [String: Any](), "history": [String: Any](), "requests": [String: Any](),
          "failed": [String: Any](),
        ]
      }
      try persist()
    } catch {
      flock(ownerLock, LOCK_UN)
      close(ownerLock)
      throw error
    }
  }

  deinit {
    flock(ownerLock, LOCK_UN)
    close(ownerLock)
  }

  static func key(_ thread: String, _ turn: String) throws -> String {
    guard !thread.isEmpty, !turn.isEmpty, !thread.contains("/"), !turn.contains("/") else {
      throw RouterFailure("Invalid thread or turn identity.")
    }
    return thread + "/" + turn
  }

  func bound(_ key: String) throws -> UUID? {
    try lock.withLock {
      if try RouterJSON.map(state, "failed")[key] != nil {
        throw RouterFailure(
          "This turn stopped after an uncertain or failed request. Start a new turn.")
      }
      guard let value = try RouterJSON.map(state, "bindings")[key] else { return nil }
      guard let text = value as? String, let id = UUID(uuidString: text) else {
        throw RouterFailure("Invalid saved account binding.")
      }
      return id
    }
  }

  func bind(_ key: String, account: UUID) throws {
    try lock.withLock {
      if let existing = try bound(key) {
        guard existing == account else {
          throw RouterFailure("An active turn cannot change accounts.")
        }
        return
      }
      try put("bindings", key, account.uuidString.lowercased())
      try persist()
    }
  }

  func registerTitle(thread: String, cwd: String, account: UUID) throws {
    try lock.withLock {
      let entry: [String: Any] = ["cwd": cwd, "account": account.uuidString.lowercased()]
      if let current = try RouterJSON.map(state, "titles")[thread] {
        guard try RouterJSON.data(current) == RouterJSON.data(entry) else {
          throw RouterFailure("A title task cannot change routing context.")
        }
      } else {
        try put("titles", thread, entry)
        try persist()
      }
    }
  }

  func title(_ thread: String) throws -> UUID? {
    try lock.withLock {
      guard let entry = try RouterJSON.map(state, "titles")[thread] as? [String: Any] else {
        return nil
      }
      guard let id = UUID(uuidString: try RouterJSON.text(entry, "account")) else {
        throw RouterFailure("Invalid title account binding.")
      }
      return id
    }
  }

  func completedAccount(_ thread: String) throws -> UUID {
    try lock.withLock {
      guard let text = try RouterJSON.map(state, "completed")[thread] as? String,
        let id = UUID(uuidString: text)
      else {
        throw RouterFailure("Compaction requires a completed turn binding.")
      }
      return id
    }
  }

  func stop(_ thread: String, turn: String) throws {
    try lock.withLock {
      let key = try Self.key(thread, turn)
      guard let account = try bound(key) else {
        throw RouterFailure("Cannot finish an unbound turn.")
      }
      try put("completed", thread, account.uuidString.lowercased())
      try persist()
    }
  }

  func history(_ id: String, thread: String) throws -> [String: Any] {
    try lock.withLock {
      let histories = try RouterJSON.map(state, "history")
      var cursor: String? = id
      var visited = Set<String>()
      var chain: [[String: Any]] = []
      while let current = cursor {
        guard visited.insert(current).inserted, visited.count <= 100000,
          let record = histories[current] as? [String: Any], record["thread"] as? String == thread
        else {
          throw RouterFailure(
            "The previous response is unknown, corrupt, or belongs to another task.")
        }
        chain.append(record)
        if record["previous"] == nil {
          cursor = nil
        } else {
          cursor = try RouterJSON.text(record, "previous")
        }
      }
      guard var result = chain.first else { throw RouterFailure("Missing response history.") }
      var input: [[String: Any]] = []
      var byteCount = 0
      for (index, record) in chain.reversed().enumerated() {
        input += try readMessages(record, field: "input", byteCount: &byteCount)
        if index < chain.count - 1 {
          input += try readMessages(record, field: "output", byteCount: &byteCount)
        }
      }
      result["input"] = input
      result["output"] = try readMessages(result, field: "output", byteCount: &byteCount)
      return result
    }
  }

  func saveHistory(id: String, value: [String: Any]) throws {
    try lock.withLock {
      try storeHistory(id, value: value)
      try persist()
    }
  }

  func begin(_ fingerprint: String, turn: String) throws {
    try lock.withLock {
      guard try bound(turn) != nil else {
        throw RouterFailure("Inference requires an immutable account binding.")
      }
      let next: String
      if let request = try RouterJSON.map(state, "requests")[fingerprint] {
        guard let request = request as? [String: Any], request["turn"] as? String == turn,
          request["state"] as? String == "connection_limited"
        else {
          throw RouterFailure(
            "This inference request was already submitted; automatic replay is forbidden.")
        }
        next = "retrying"
      } else {
        next = "forwarding"
      }
      try put("requests", fingerprint, ["turn": turn, "state": next])
      try persist()
    }
  }

  /// Records an explicit pre-response rejection, permitting one Engine-owned resubmission.
  func rejectConnectionLimit(_ fingerprint: String, turn: String) throws {
    try lock.withLock {
      guard let request = try RouterJSON.map(state, "requests")[fingerprint] as? [String: Any],
        request["turn"] as? String == turn, request["state"] as? String == "forwarding"
      else {
        throw RouterFailure(
          "Cannot recover this request from another WebSocket connection limit. Start a new turn.")
      }
      try put("requests", fingerprint, ["turn": turn, "state": "connection_limited"])
      try persist()
    }
  }

  func complete(_ fingerprint: String, turn: String, response: String, history: [String: Any])
    throws
  {
    try lock.withLock {
      try storeHistory(response, value: history)
      try finish(fingerprint, turn: turn)
    }
  }

  func finish(_ fingerprint: String, turn: String) throws {
    try lock.withLock {
      guard let request = try RouterJSON.map(state, "requests")[fingerprint] as? [String: Any],
        request["turn"] as? String == turn,
        ["forwarding", "retrying"].contains(request["state"] as? String)
      else { throw RouterFailure("Cannot complete a request that was not submitted by this turn.") }
      try put("requests", fingerprint, ["turn": turn, "state": "completed"])
      try persist()
    }
  }

  func fail(_ turn: String) throws {
    try lock.withLock {
      try put("failed", turn, true)
      try persist()
    }
  }

  private func put(_ collection: String, _ key: String, _ value: Any) throws {
    var values = try RouterJSON.map(state, collection)
    values[key] = value
    state[collection] = values
  }

  private func storeHistory(_ id: String, value: [String: Any]) throws {
    guard try RouterJSON.map(state, "history")[id] == nil else {
      throw RouterFailure("The account reused a response identity.")
    }
    var stored = value
    for field in ["input", "output"] {
      stored[field] = try RouterJSON.array(value, field).map { item -> String in
        let data = try RouterJSON.data(item)
        let digest = RouterJSON.hash(data)
        let file = messagesDirectory.appending(path: digest + ".json")
        if !FileManager.default.fileExists(atPath: file.path) {
          try RouterJSON.writePrivate(data, to: file)
        }
        return digest
      }
    }
    try put("history", id, stored)
  }

  private func readMessages(_ record: [String: Any], field: String, byteCount: inout Int) throws
    -> [[String: Any]]
  {
    guard let keys = record[field] as? [String] else {
      throw RouterFailure("Invalid saved response history.")
    }
    return try keys.map { key in
      guard key.count == 64, key.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
        throw RouterFailure("Invalid history content identity.")
      }
      let data = try Data(contentsOf: messagesDirectory.appending(path: key + ".json"))
      byteCount += data.count
      guard byteCount <= 64 * 1024 * 1024, RouterJSON.hash(data) == key else {
        throw RouterFailure("Response history is corrupt or exceeds the supported size.")
      }
      return try RouterJSON.object(data)
    }
  }

  private func persist() throws {
    try RouterJSON.writePrivate(RouterJSON.data(state), to: file)
  }
}
