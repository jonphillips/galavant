import Dependencies
import Foundation
import GRDB
import Synchronization

/// Lifecycle decisions are independent of UIKit and the sync engine.
public struct SyncSuspensionPlan: Sendable {
  public enum Effect: Equatable, Sendable {
    case beginTask, stop, suspend, endTask, resume, start
  }
  private var background = false
  private var suspended = false
  private var stopped = false
  private var expired = false
  private var deniedStart = false
  var isExpired: Bool { expired }

  public init() {}

  public mutating func enterBackground() -> [Effect] {
    guard !background && !expired else { return [] }
    background = true
    return [.beginTask]
  }

  public mutating func expire(quiet: Bool) -> [Effect] {
    guard !expired else { return [] }
    expired = true
    guard quiet else { return [.endTask] }
    stopped = true
    suspended = true
    return [.stop, .suspend, .endTask]
  }

  public mutating func bootstrapExpired() {
    expired = true
    suspended = true
  }

  public mutating func allowStart() -> Bool {
    guard !expired else {
      deniedStart = true
      return false
    }
    return true
  }

  public mutating func enterForeground() -> [Effect] {
    guard background || expired || suspended || deniedStart else { return [] }
    var effects: [Effect] = [.endTask]
    if suspended { effects.append(.resume) }
    if stopped || deniedStart { effects.append(.start) }
    self = Self()
    return effects
  }
}

/// Serializes starts and redrains, while expiration can synchronously fence them.
public final class SyncStartGate: Sendable {
  private struct State {
    var plan = SyncSuspensionPlan()
    var operationCount = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
  }
  private let state = Mutex(State())
  var operationCount: Int { state.withLock { $0.operationCount } }

  public init() {}

  public func run<T>(_ operation: () async -> T) async -> T {
    await withCheckedContinuation { continuation in
      let begin = state.withLock { state in
        state.operationCount += 1
        if state.operationCount == 1 { return true }
        state.waiters.append(continuation)
        return false
      }
      if begin { continuation.resume() }
    }
    defer {
      let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
        state.operationCount -= 1
        return state.waiters.isEmpty ? nil : state.waiters.removeFirst()
      }
      next?.resume()
    }
    return await operation()
  }

  /// Call only inside `run`; redrain must not enqueue a second operation.
  public func start(_ operation: () async throws -> Void) async throws {
    let allowed = state.withLock { $0.plan.allowStart() }
    guard allowed else { return }
    try await operation()
  }

  public func enterBackground() -> [SyncSuspensionPlan.Effect] {
    state.withLock { $0.plan.enterBackground() }
  }

  /// Executes the stop and suspension under the same lock as the start check.
  public func expire(isSynchronizing: () -> Bool, perform: (SyncSuspensionPlan.Effect) -> Void) -> Bool {
    state.withLock { state in
      let quiet = state.operationCount == 0 && !isSynchronizing()
      let effects = state.plan.expire(quiet: quiet)
      effects.forEach(perform)
      return quiet
    }
  }

  public func bootstrapExpired(perform: () -> Void) {
    state.withLock { state in
      state.plan.bootstrapExpired()
      perform()
    }
  }

  public func shouldExitBootstrap(for error: any Error) -> Bool {
    guard let error = error as? DatabaseError, error.isInterruptionError else { return false }
    return state.withLock { $0.plan.isExpired }
  }

  public func repeatBootstrapSuspensionIfExpired(perform: () -> Void) {
    state.withLock { state in
      if state.plan.isExpired { perform() }
    }
  }

  public func enterForeground(perform: (SyncSuspensionPlan.Effect) -> Void) {
    state.withLock { state in
      state.plan.enterForeground().forEach(perform)
    }
  }
}

private enum SyncStartGateKey: DependencyKey {
  static var liveValue: SyncStartGate { SyncStartGate() }
  static var testValue: SyncStartGate { SyncStartGate() }
}

private enum SyncEngineAvailableKey: DependencyKey {
  static let liveValue = false
  static let testValue = true
}

extension DependencyValues {
  public var syncStartGate: SyncStartGate {
    get { self[SyncStartGateKey.self] }
    set { self[SyncStartGateKey.self] = newValue }
  }
  public var syncEngineAvailable: Bool {
    get { self[SyncEngineAvailableKey.self] }
    set { self[SyncEngineAvailableKey.self] = newValue }
  }
}
