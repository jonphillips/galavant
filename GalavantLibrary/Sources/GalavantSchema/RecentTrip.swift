import Dependencies
import Foundation

/// The trip the user most recently engaged with (selected a capsule for, or opened
/// to plan), persisted in the **app-group** defaults so the share extension — a
/// separate process — can default a capture onto it. Written by the app; read by
/// the capture flow. An injectable boundary (UserDefaults is I/O) so the models
/// that use it stay testable.
public struct RecentTripStore: Sendable {
  public var read: @Sendable () -> UUID?
  public var record: @Sendable (UUID?) -> Void

  public init(read: @escaping @Sendable () -> UUID?, record: @escaping @Sendable (UUID?) -> Void) {
    self.read = read
    self.record = record
  }
}

extension RecentTripStore: DependencyKey {
  public static let liveValue = RecentTripStore(
    // `UserDefaults` isn't Sendable, so resolve the app-group suite inside each
    // closure (cheap) rather than capturing one instance.
    read: {
      UserDefaults(suiteName: GalavantStorage.appGroupID)?
        .string(forKey: recentTripKey)
        .flatMap(UUID.init(uuidString:))
    },
    record: { id in
      guard let defaults = UserDefaults(suiteName: GalavantStorage.appGroupID) else { return }
      if let id {
        defaults.set(id.uuidString, forKey: recentTripKey)
      } else {
        defaults.removeObject(forKey: recentTripKey)
      }
    }
  )

  private static let recentTripKey = "recentTripID"

  /// No persistence in tests/previews unless overridden per case.
  public static let testValue = RecentTripStore(read: { nil }, record: { _ in })
}

extension DependencyValues {
  public var recentTripStore: RecentTripStore {
    get { self[RecentTripStore.self] }
    set { self[RecentTripStore.self] = newValue }
  }
}
