import Foundation

/// Transport deadlines are independent of model output and never authorize replay.
struct RouterConnectionPolicy: Sendable {
  static let live = Self(keepAlive: 20, probe: 10, send: 30, receive: 180)
  let keepAlive: TimeInterval
  let probe: TimeInterval
  let send: TimeInterval
  let receive: TimeInterval
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
}
