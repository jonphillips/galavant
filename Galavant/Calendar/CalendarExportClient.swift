import Dependencies
import EventKit
import Foundation
import GalavantSchema

/// Injectable EventKit boundary (mirrors `DirectionsClient`/`UnsplashClient`) —
/// the live write side of the one-way, per-device Galavant→Calendar mirror
/// (BACKLOG "Export itinerary to Apple Calendar / iCal"). Every verb the
/// export/reconcile pass needs, no more: request access, find-or-create the
/// dedicated per-trip **local** calendar, and create/update/delete/check
/// events by identifier. The live value touches a single shared
/// `EKEventStore`; the test value is a deterministic stub so view models built
/// on this stay testable without a real calendar database.
struct CalendarExportClient: Sendable {
  /// Request full calendar access; `false` on denial — the caller surfaces a
  /// clear alert rather than silently no-op'ing or crashing.
  var requestAccess: @Sendable () async throws -> Bool
  /// Find (by exact title) or create a dedicated **local** calendar — never a
  /// CalDAV/shared/CloudKit source, per the one-way-mirror design: Galavant
  /// never writes into a calendar another device or account could be reading.
  /// Returns the calendar's `calendarIdentifier`.
  var findOrCreateCalendar: @Sendable (_ title: String) throws -> String
  /// Whether an event with this identifier still exists — used on re-export to
  /// tell "safe to update in place" from "was deleted out from under us
  /// (Calendar.app, or a stale identifier), recreate it instead."
  var eventExists: @Sendable (_ identifier: String) -> Bool
  /// Create an event in the given calendar; returns its new `eventIdentifier`.
  var createEvent: @Sendable (_ item: CalendarExportItem, _ calendarIdentifier: String) throws -> String
  /// Update an existing event's fields in place.
  var updateEvent: @Sendable (_ identifier: String, _ item: CalendarExportItem) throws -> Void
  /// Delete an event by identifier. No-op if it no longer exists.
  var deleteEvent: @Sendable (_ identifier: String) throws -> Void
}

/// A single shared `EKEventStore`, per Apple's guidance (reuse one store per
/// app rather than creating one per call). EventKit's store/calendar/event
/// types aren't `Sendable`-checked, so this box is `@unchecked Sendable`: the
/// live client's closures all funnel through this one instance, and EventKit's
/// own APIs are safe to call from any thread/actor.
private final class EventKitStore: @unchecked Sendable {
  let store = EKEventStore()
}

extension CalendarExportClient: DependencyKey {
  static let liveValue: CalendarExportClient = {
    let box = EventKitStore()
    return CalendarExportClient(
      requestAccess: {
        try await box.store.requestFullAccessToEvents()
      },
      findOrCreateCalendar: { title in
        if let existing = box.store.calendars(for: .event).first(where: { $0.title == title }) {
          return existing.calendarIdentifier
        }
        guard
          let localSource = box.store.sources.first(where: { $0.sourceType == .local })
            ?? box.store.defaultCalendarForNewEvents?.source
        else {
          throw CalendarExportError.noLocalSource
        }
        let calendar = EKCalendar(for: .event, eventStore: box.store)
        calendar.title = title
        calendar.source = localSource
        try box.store.saveCalendar(calendar, commit: true)
        return calendar.calendarIdentifier
      },
      eventExists: { identifier in
        box.store.event(withIdentifier: identifier) != nil
      },
      createEvent: { item, calendarIdentifier in
        guard let calendar = box.store.calendar(withIdentifier: calendarIdentifier) else {
          throw CalendarExportError.calendarNotFound
        }
        let event = EKEvent(eventStore: box.store)
        apply(item, to: event)
        event.calendar = calendar
        try box.store.save(event, span: .thisEvent)
        return event.eventIdentifier
      },
      updateEvent: { identifier, item in
        guard let event = box.store.event(withIdentifier: identifier) else {
          throw CalendarExportError.eventNotFound
        }
        apply(item, to: event)
        try box.store.save(event, span: .thisEvent)
      },
      deleteEvent: { identifier in
        guard let event = box.store.event(withIdentifier: identifier) else { return }
        try box.store.remove(event, span: .thisEvent)
      }
    )
  }()

  private static func apply(_ item: CalendarExportItem, to event: EKEvent) {
    event.title = item.title
    event.notes = item.notes
    event.startDate = item.start
    event.endDate = item.end
    event.isAllDay = item.isAllDay
  }

  /// Deterministic stub — no real calendar, no network. `findOrCreateCalendar`
  /// and `createEvent` hand back fixed/fresh identifiers so model-level tests
  /// can exercise the export flow without EventKit.
  static let testValue = CalendarExportClient(
    requestAccess: { true },
    findOrCreateCalendar: { _ in "test-calendar" },
    eventExists: { _ in false },
    createEvent: { _, _ in UUID().uuidString },
    updateEvent: { _, _ in },
    deleteEvent: { _ in }
  )
}

enum CalendarExportError: Error, LocalizedError {
  case noLocalSource
  case calendarNotFound
  case eventNotFound

  var errorDescription: String? {
    switch self {
    case .noLocalSource: "No local calendar source is available on this device."
    case .calendarNotFound: "The Galavant calendar could not be found."
    case .eventNotFound: "The calendar event could not be found."
    }
  }
}

extension DependencyValues {
  var calendarExportClient: CalendarExportClient {
    get { self[CalendarExportClient.self] }
    set { self[CalendarExportClient.self] = newValue }
  }
}

// MARK: - M7 Slice 0 observation spike

/// The EventKit facts the M7 spike is allowed to hold in memory. This is
/// intentionally not a schema record: Slice 0 proves observation and matching
/// before any reconciliation outcome, binding, or history is made durable.
struct CalendarObservedEvent: Equatable, Sendable, Identifiable {
  let id: String
  /// `eventIdentifier` is not guaranteed for every subscribed/shared EventKit
  /// record. The spike can show such an event, but deliberately does not pretend it
  /// can follow a later move outside the trip's query window.
  var eventIdentifier: String?
  var title: String
  var location: String?
  var latitude: Double?
  var longitude: Double?
  var startDate: Date
  var endDate: Date
  var isAllDay: Bool
  var calendarTitle: String

  init(event: EKEvent) {
    // EventKit exposes these as `String!`: shared and subscribed feeds can leave
    // either nil. Snapshot them safely so an odd real-world event never crashes the
    // device gate. A Calendar-item identifier or immutable display fields provide
    // the list-only fallback identity; neither becomes a durable event binding.
    eventIdentifier = event.eventIdentifier.flatMap { $0.isEmpty ? nil : $0 }
    let rawTitle = event.title ?? ""
    title = rawTitle.isEmpty ? "Untitled Event" : rawTitle
    location = event.location
    latitude = event.structuredLocation?.geoLocation?.coordinate.latitude
    longitude = event.structuredLocation?.geoLocation?.coordinate.longitude
    startDate = event.startDate
    endDate = event.endDate
    isAllDay = event.isAllDay
    let rawCalendarTitle = event.calendar.title ?? ""
    calendarTitle = rawCalendarTitle.isEmpty ? "Untitled Calendar" : rawCalendarTitle
    id = eventIdentifier
      ?? event.calendarItemIdentifier
      ?? [calendarTitle, title, String(startDate.timeIntervalSinceReferenceDate),
          String(endDate.timeIntervalSinceReferenceDate), location ?? ""].joined(separator: "|")
  }
}

/// Injectable read-only EventKit boundary for M7 Slice 0. It requests **full**
/// event access, queries all visible calendars in a trip's supplied interval, and
/// exposes `EKEventStoreChangedNotification` so the spike can re-query after an
/// external edit or permission change. No closure here creates, updates, or
/// deletes a calendar event, and the client owns no persisted identifier mapping.
struct CalendarObservationClient: Sendable {
  var requestFullAccess: @Sendable () async throws -> Bool
  var hasFullAccess: @Sendable () -> Bool
  var events: @Sendable (_ interval: DateInterval) throws -> [CalendarObservedEvent]
  /// Looks up the in-memory spike's current event identity after it leaves the
  /// trip query. A non-nil value outside the interval proves "moved", while nil
  /// remains an unknown-visibility result — never a deletion conclusion.
  var event: @Sendable (_ identifier: String) -> CalendarObservedEvent?
  var changes: @Sendable () -> AsyncStream<Void>
}

extension CalendarObservationClient: DependencyKey {
  static let liveValue: CalendarObservationClient = {
    let box = EventKitStore()
    return CalendarObservationClient(
      requestFullAccess: {
        try await box.store.requestFullAccessToEvents()
      },
      hasFullAccess: {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
      },
      events: { interval in
        let predicate = box.store.predicateForEvents(
          withStart: interval.start, end: interval.end, calendars: nil)
        return box.store.events(matching: predicate).map(CalendarObservedEvent.init(event:))
      },
      event: { identifier in
        box.store.event(withIdentifier: identifier).map(CalendarObservedEvent.init(event:))
      },
      changes: {
        AsyncStream { continuation in
          let task = Task {
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
              continuation.yield()
            }
            continuation.finish()
          }
          continuation.onTermination = { _ in task.cancel() }
        }
      }
    )
  }()

  static let testValue = CalendarObservationClient(
    requestFullAccess: { true },
    hasFullAccess: { true },
    events: { _ in [] },
    event: { _ in nil },
    changes: { AsyncStream { $0.finish() } }
  )
}

extension DependencyValues {
  var calendarObservationClient: CalendarObservationClient {
    get { self[CalendarObservationClient.self] }
    set { self[CalendarObservationClient.self] = newValue }
  }
}
