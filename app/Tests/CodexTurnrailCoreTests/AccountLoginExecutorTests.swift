import Darwin
import Foundation
import Testing

@testable import CodexTurnrailCore

struct AccountLoginExecutorTests {
  @Test(.timeLimit(.minutes(1)), arguments: [false, true], [0, 6])
  func cancellationStopsTheOwnedProcessEvenWhenItIgnoresTermination(
    ignoreTermination: Bool, startupDelay: Int
  )
    async throws
  {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pidFile = root.appending(path: "login.pid")
    let script =
      (ignoreTermination ? "trap '' TERM; " : "")
      + "/bin/sleep \(startupDelay); "
      + "echo $$ > \"$1.pending\" && /bin/mv \"$1.pending\" \"$1\" && exec /bin/sleep 60"
    let (readiness, ready) = AsyncThrowingStream<Void, any Error>.makeStream()
    let task = Task {
      do {
        let result = try await AccountLoginExecutor.live.execute(
          AccountAuthenticationCommand(
            executableURL: URL(filePath: "/bin/sh"),
            arguments: ["-c", script, "turnrail-login-test", pidFile.path],
            environment: [:], expectedEmail: nil
          ))
        ready.finish(
          throwing: RouterFailure("The fixture login exited before readiness: \(result.exitCode)."))
        return result
      } catch {
        ready.finish(throwing: error)
        throw error
      }
    }
    let observer = Task {
      do {
        while !FileManager.default.fileExists(atPath: pidFile.path) {
          try await Task.sleep(for: .milliseconds(10))
        }
        ready.yield(())
        ready.finish()
      } catch {
        ready.finish(throwing: error)
      }
    }
    defer {
      observer.cancel()
      task.cancel()
      ready.finish()
    }
    // The test time limit bounds startup without treating scheduler delay as cancellation failure.
    var iterator = readiness.makeAsyncIterator()
    try #require(try await iterator.next() != nil)
    let pid = try #require(
      Int32(
        String(contentsOf: pidFile, encoding: .utf8)
          .trimmingCharacters(in: .whitespacesAndNewlines)))
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Cancellation must throw after terminating the process")
    } catch is CancellationError {
      let status = kill(pid, 0)
      let failure = errno
      #expect(status == -1)
      #expect(failure == ESRCH)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func drainsBothOutputPipesWhileTheProcessIsRunning() async throws {
    let result = try await AccountLoginExecutor.live.execute(
      AccountAuthenticationCommand(
        executableURL: URL(filePath: "/bin/sh"),
        arguments: [
          "-c",
          """
          i=0
          while [ "$i" -lt 5000 ]; do
            printf 'stdout-0123456789\\n'
            printf 'stderr-0123456789\\n' >&2
            i=$((i + 1))
          done
          exit 7
          """,
        ],
        environment: [:], expectedEmail: nil
      ))
    #expect(result.exitCode == 7)
    #expect(result.standardOutput == String(repeating: "stdout-0123456789\n", count: 5000))
    #expect(result.standardError == String(repeating: "stderr-0123456789\n", count: 5000))
  }

  @Test
  func aCancelledTaskDoesNotStartLogin() async throws {
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await AccountLoginExecutor.live.execute(
        AccountAuthenticationCommand(
          executableURL: URL(filePath: "/nonexistent-login-must-not-start"),
          arguments: [],
          environment: [:], expectedEmail: nil
        ))
    }
    do {
      _ = try await task.value
      Issue.record("An already cancelled task must not start login")
    } catch is CancellationError {
      // A launch attempt would throw a file-not-found error instead.
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func concurrentLoginsDrainOutputWithoutExhaustingTheCooperativeExecutor() async throws {
    let count = ProcessInfo.processInfo.activeProcessorCount + 1
    try await withThrowingTaskGroup(of: CommandResult.self) { group in
      for _ in 0..<count {
        group.addTask {
          try await AccountLoginExecutor.live.execute(
            AccountAuthenticationCommand(
              executableURL: URL(filePath: "/bin/sh"),
              arguments: [
                "-c",
                """
                i=0
                while [ "$i" -lt 5000 ]; do
                  printf 'output-0123456789\\n'
                  printf 'error-0123456789\\n' >&2
                  i=$((i + 1))
                done
                """,
              ],
              environment: [:], expectedEmail: nil
            ))
        }
      }
      var completed = 0
      for try await result in group {
        #expect(result.exitCode == 0)
        #expect(result.standardOutput == String(repeating: "output-0123456789\n", count: 5000))
        #expect(result.standardError == String(repeating: "error-0123456789\n", count: 5000))
        completed += 1
      }
      #expect(completed == count)
    }
  }
}
