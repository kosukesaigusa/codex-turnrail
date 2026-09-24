import Foundation

/// Bound transport operations; the official Engine owns model-response waiting.
struct RouterConnectionPolicy: Sendable {
  static let live = Self(keepAlive: 20, probe: 10, send: 30)
  let keepAlive: TimeInterval
  let probe: TimeInterval
  let send: TimeInterval
}

/// Completion wins once; close, timeout, and Foundation callbacks can race.
final class RouterAsyncResult<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private let ready = DispatchGroup()
  private var result: Result<T, Error>?

  init() { ready.enter() }

  func complete(_ result: Result<T, Error>) {
    lock.withLock {
      guard self.result == nil else { return }
      self.result = result
      ready.leave()
    }
  }

  func wait(seconds: TimeInterval, timeout: @autoclosure () -> Error) throws -> T {
    guard ready.wait(timeout: .now() + seconds) == .success else { throw timeout() }
    return try lock.withLock { try result!.get() }
  }

  func wait() throws -> T {
    ready.wait()
    return try lock.withLock { try result!.get() }
  }
}
