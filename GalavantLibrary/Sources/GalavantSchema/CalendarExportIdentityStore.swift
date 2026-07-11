import Dependencies
import Foundation

/// The per-trip mapping from a stop (`TripIdea.ID`) to the EventKit event
/// identifier this **device** created for it — the state that lets a re-export
/// reconcile (update/delete) instead of duplicating (BACKLOG "Export itinerary
/// to Apple Calendar / iCal").
///
/// **Local-only, `UserDefaults`-backed — never CloudKit-synced.** This is the
/// single most important property of this type: an `EKEvent.eventIdentifier`
/// is meaningful only on the device that created it (a second iPhone/iPad has
/// its own local EventKit database), so persisting this mapping through the
/// synced schema would silently corrupt it the moment a second device opened
/// the trip. The settled design is a one-way, per-device projection (Galavant
/// writes, nothing reads back, no shared calendar) — this store is the local
/// half of that contract, keyed `"calendarExport.<tripID>"`, mirroring
/// `RecentTripStore`'s shape (an injectable boundary so callers stay testable).
public struct CalendarExportIdentityStore: Sendable {
  public var mapping: @Sendable (_ tripID: Trip.ID) -> [TripIdea.ID: String]
  public var setMapping: @Sendable (_ tripID: Trip.ID, _ mapping: [TripIdea.ID: String]) -> Void

  public init(
    mapping: @escaping @Sendable (_ tripID: Trip.ID) -> [TripIdea.ID: String],
    setMapping: @escaping @Sendable (_ tripID: Trip.ID, _ mapping: [TripIdea.ID: String]) -> Void
  ) {
    self.mapping = mapping
    self.setMapping = setMapping
  }
}

extension CalendarExportIdentityStore: DependencyKey {
  public static let liveValue = CalendarExportIdentityStore(
    // `UserDefaults` isn't Sendable, so resolve `.standard` inside each closure
    // (cheap) rather than capturing one instance — same pattern as
    // `RecentTripStore`. Plain `.standard` (not the app-group suite): only the
    // app touches EventKit, never the share extension.
    mapping: { tripID in
      guard let data = UserDefaults.standard.data(forKey: key(for: tripID)),
        let decoded = try? JSONDecoder().decode([UUID: String].self, from: data)
      else { return [:] }
      return decoded
    },
    setMapping: { tripID, mapping in
      guard let data = try? JSONEncoder().encode(mapping) else { return }
      UserDefaults.standard.set(data, forKey: key(for: tripID))
    }
  )

  private static func key(for tripID: Trip.ID) -> String {
    "calendarExport.\(tripID.uuidString)"
  }

  /// No persistence in tests/previews unless overridden per case.
  public static let testValue = CalendarExportIdentityStore(
    mapping: { _ in [:] },
    setMapping: { _, _ in }
  )
}

extension DependencyValues {
  public var calendarExportIdentityStore: CalendarExportIdentityStore {
    get { self[CalendarExportIdentityStore.self] }
    set { self[CalendarExportIdentityStore.self] = newValue }
  }
}
