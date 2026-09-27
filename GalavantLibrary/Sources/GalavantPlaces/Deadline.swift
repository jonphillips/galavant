import Foundation
import Synchronization

/// Race `operation` against `timeout` on `clock`, returning `fallback` when the
/// deadline wins.
///
/// Deliberately *non-cooperative*: a task group would wait for its losing child, so
/// a dependency that ignores cancellation (an on-device model session, a MapKit
/// request stuck behind the network) would still hold the caller hostage. Here the
/// loser is cancelled and abandoned instead of awaited — the capture sheet's
/// optional enrichment steps degrade to "no answer" rather than hang "Reading page…"
/// forever.
func withDeadline<T: Sendable>(
  _ timeout: Duration,
  clock: any Clock<Duration>,
  fallback: T,
  operation: @escaping @Sendable () async -> T
) async -> T {
  let race = DeadlineRace<T>()
  return await withCheckedContinuation { continuation in
    race.start(continuation)
    let work = Task {
      let value = await operation()
      race.finish(with: value)
    }
    let timer = Task {
      do {
        try await clock.sleep(for: timeout)
      } catch {
        return  // Cancelled: the operation already won.
      }
      race.finish(with: fallback)
    }
    race.track(work, timer)
  }
}

/// The once-only resumption both racers funnel through: the first `finish` resumes
/// the continuation and cancels both tasks; every later call is a no-op.
private final class DeadlineRace<T: Sendable>: Sendable {
  private struct State {
    var continuation: CheckedContinuation<T, Never>?
    var tasks: [Task<Void, Never>] = []
    var finished = false
  }

  private let state = Mutex(State())

  func start(_ continuation: CheckedContinuation<T, Never>) {
    state.withLock { $0.continuation = continuation }
  }

  func track(_ tasks: Task<Void, Never>...) {
    let finished = state.withLock { state in
      if !state.finished { state.tasks = tasks }
      return state.finished
    }
    // A racer finished before the tasks were recorded — cancel the survivor now.
    if finished { tasks.forEach { $0.cancel() } }
  }

  func finish(with value: T) {
    let (continuation, tasks) = state.withLock { state in
      guard !state.finished else {
        return (CheckedContinuation<T, Never>?.none, [Task<Void, Never>]())
      }
      state.finished = true
      defer {
        state.continuation = nil
        state.tasks = []
      }
      return (state.continuation, state.tasks)
    }
    continuation?.resume(returning: value)
    tasks.forEach { $0.cancel() }
  }
}
