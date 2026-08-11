import Dependencies
import Foundation
import SQLiteData

/// Whether a stop's reservation time is still entered in Galavant or is now
/// observed from the shared Calendar. The `.linked` binding itself is local:
/// EventKit identifiers have device-local meaning and cannot enter the synced
/// schema. Slice 3 promotes the *outcome* and review ledger, not this binding.
public enum CalendarTimeAuthority: String, Codable, Equatable, Sendable {
  case manual
  case linked
}

/// The Calendar fact this device applied to a linked stop. This deliberately
/// covers only the ordinary, representable EventKit shapes in Slice 2. Slice 4
/// expands the temporal model for cross-day, recurrence, availability, and
/// time-zone semantics rather than guessing at any of them here.
public enum CalendarCommitment: Codable, Equatable, Sendable {
  case allDay(date: Date)
  case timed(start: Date, end: Date)

  public init?(event: CalendarObservedEvent, calendar: Calendar = .current) {
    if event.isAllDay {
      self = .allDay(date: calendar.startOfDay(for: event.startDate))
      return
    }
    guard event.endDate > event.startDate,
      calendar.isDate(event.startDate, inSameDayAs: event.endDate)
    else { return nil }
    self = .timed(start: event.startDate, end: event.endDate)
  }

  public var pinnedDate: Date {
    switch self {
    case let .allDay(date): date
    case let .timed(start, _): start
    }
  }

  public func schedule(on day: DayNumber, calendar: Calendar = .current) -> Schedule {
    switch self {
    case .allDay:
      .day(day)
    case let .timed(start, end):
      .timed(day, start: clockTime(start, calendar: calendar), end: clockTime(end, calendar: calendar))
    }
  }

  private func clockTime(_ date: Date, calendar: Calendar) -> String {
    let components = calendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
  }
}

/// A device-local EventKit binding. `eventID` is never synced: it tells this
/// device which observed event remains authoritative for one itinerary stop.
public struct CalendarLinkedStop: Codable, Equatable, Sendable {
  public var stopID: TripIdea.ID
  public var eventID: String
  public var commitment: CalendarCommitment
  public var observedAt: Date
  /// The last Calendar title seen for this binding. It is optional so existing
  /// device-local Slice 2 payloads continue to decode after this field was added.
  public var eventTitle: String?
  /// A Calendar event can remain a valid binding after being moved beyond the
  /// trip's dates. Keep the observed fact for review, but never turn absence or
  /// an out-of-scope date into a deletion or an itinerary write.
  public var movedOutsideTripCommitment: CalendarCommitment?

  public init(
    stopID: TripIdea.ID,
    eventID: String,
    commitment: CalendarCommitment,
    observedAt: Date,
    eventTitle: String? = nil,
    movedOutsideTripCommitment: CalendarCommitment? = nil
  ) {
    self.stopID = stopID
    self.eventID = eventID
    self.commitment = commitment
    self.observedAt = observedAt
    self.eventTitle = eventTitle
    self.movedOutsideTripCommitment = movedOutsideTripCommitment
  }
}

/// A reviewable, device-local audit record of an authoritative Calendar update.
/// It retains the EventKit binding ID needed on this device; Slice 3 derives a
/// separate shared ledger outcome from its semantic source fingerprint.
public struct CalendarReconciliationHistoryEntry: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: String, Codable, Equatable, Sendable, QueryBindable {
    case linked
    case updated
    case movedOutsideTrip
  }

  public var id: UUID
  public var kind: Kind
  public var stopID: TripIdea.ID
  public var eventID: String
  public var eventTitle: String
  public var previous: CalendarCommitment?
  public var current: CalendarCommitment
  /// A one-way hash of the server event identity/revision and its semantic
  /// snapshot. It intentionally excludes the device-local EventKit identifier
  /// and the device's observation time; Slice 3 combines it with the outcome to
  /// make a deterministic CloudKit record ID. Optional keeps Slice 2's stored
  /// UserDefaults payloads decodable.
  public var sourceFingerprint: String?
  public var appliedAt: Date

  public init(
    id: UUID,
    kind: Kind,
    stopID: TripIdea.ID,
    eventID: String,
    eventTitle: String,
    previous: CalendarCommitment? = nil,
    current: CalendarCommitment,
    sourceFingerprint: String? = nil,
    appliedAt: Date
  ) {
    self.id = id
    self.kind = kind
    self.stopID = stopID
    self.eventID = eventID
    self.eventTitle = eventTitle
    self.previous = previous
    self.current = current
    self.sourceFingerprint = sourceFingerprint
    self.appliedAt = appliedAt
  }
}

/// All device-local reconciliation state for one trip. It is intentionally a
/// single UserDefaults payload: EventKit bindings and their local audit context
/// remain local even after Slice 3 promotes the matching outcome to CloudKit.
public struct CalendarReconciliationLocalState: Codable, Equatable, Sendable {
  public var linkedStops: [CalendarLinkedStop]
  public var history: [CalendarReconciliationHistoryEntry]

  public init(
    linkedStops: [CalendarLinkedStop] = [],
    history: [CalendarReconciliationHistoryEntry] = []
  ) {
    self.linkedStops = linkedStops
    self.history = history
  }

  public func authority(for stopID: TripIdea.ID) -> CalendarTimeAuthority {
    linkedStops.contains { $0.stopID == stopID } ? .linked : .manual
  }
}

/// Injectable local persistence for M7's device-specific bindings and review
/// history. The main database remains the source for the applied itinerary
/// values; this store owns only EventKit-local identity and local audit state.
public struct CalendarReconciliationHistoryStore: Sendable {
  public var state: @Sendable (_ tripID: Trip.ID) -> CalendarReconciliationLocalState
  public var setState: @Sendable (_ tripID: Trip.ID, _ state: CalendarReconciliationLocalState) -> Void

  public init(
    state: @escaping @Sendable (_ tripID: Trip.ID) -> CalendarReconciliationLocalState,
    setState: @escaping @Sendable (_ tripID: Trip.ID, _ state: CalendarReconciliationLocalState) -> Void
  ) {
    self.state = state
    self.setState = setState
  }
}

extension CalendarReconciliationHistoryStore: DependencyKey {
  public static let liveValue = CalendarReconciliationHistoryStore(
    state: { tripID in
      guard let data = UserDefaults.standard.data(forKey: key(for: tripID)),
        let state = try? JSONDecoder().decode(CalendarReconciliationLocalState.self, from: data)
      else { return CalendarReconciliationLocalState() }
      return state
    },
    setState: { tripID, state in
      guard let data = try? JSONEncoder().encode(state) else { return }
      UserDefaults.standard.set(data, forKey: key(for: tripID))
    }
  )

  public static let testValue = CalendarReconciliationHistoryStore(
    state: { _ in CalendarReconciliationLocalState() },
    setState: { _, _ in }
  )

  private static func key(for tripID: Trip.ID) -> String {
    "calendarReconciliation.\(tripID.uuidString)"
  }
}

extension DependencyValues {
  public var calendarReconciliationHistoryStore: CalendarReconciliationHistoryStore {
    get { self[CalendarReconciliationHistoryStore.self] }
    set { self[CalendarReconciliationHistoryStore.self] = newValue }
  }
}
