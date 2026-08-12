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

// MARK: - M7 read-only ingestion

extension CalendarObservedEvent {
  init?(event: EKEvent) {
    // EventKit exposes these as `String!`: shared and subscribed feeds can leave
    // either nil. Snapshot them safely so an odd real-world event never crashes the
    // device gate. A Calendar-item identifier or immutable display fields provide
    // the list-only fallback identity; neither becomes a durable event binding.
    let eventIdentifier = event.eventIdentifier.flatMap { $0.isEmpty ? nil : $0 }
    let externalIdentifier: String?
    switch event.calendar.source.sourceType {
    case .calDAV:
      // iCloud and generic CalDAV are the only sources whose
      // `calendarItemExternalIdentifier` is stable across devices, so only these
      // can back a shared-ledger identity. Local/birthday IDs are device-local;
      // Exchange and subscribed IDs differ between iOS and macOS (Apple docs).
      // Everything else is still observed and shown — it just can't be promoted.
      externalIdentifier = event.calendarItemExternalIdentifier.flatMap { $0.isEmpty ? nil : $0 }
    default:
      externalIdentifier = nil
    }
    let rawTitle = event.title ?? ""
    let title = rawTitle.isEmpty ? "Untitled Event" : rawTitle
    let location = event.location
    let latitude = event.structuredLocation?.geoLocation?.coordinate.latitude
    let longitude = event.structuredLocation?.geoLocation?.coordinate.longitude
    guard let startDate = event.startDate, let endDate = event.endDate else { return nil }
    let calendar = Calendar.current
    let temporal = Self.temporal(
      for: event, startDate: startDate, endDate: endDate, calendar: calendar)
    let recurrence = Self.recurrence(for: event, temporal: temporal, calendar: calendar)
    guard !(event.hasRecurrenceRules || event.isDetached) || recurrence != nil else { return nil }
    let rawCalendarTitle = event.calendar.title
    let calendarTitle = rawCalendarTitle.isEmpty ? "Untitled Calendar" : rawCalendarTitle
    let fallbackIdentifier = [
      calendarTitle, title, temporal.identityDescription, location ?? "",
    ].joined(separator: "|")
    let calendarItemIdentifier = event.calendarItemIdentifier
    let stableIdentifier = eventIdentifier
      ?? (calendarItemIdentifier.isEmpty ? nil : calendarItemIdentifier)
    self.init(
      id: stableIdentifier ?? fallbackIdentifier,
      hasStableLocalIdentity: stableIdentifier != nil,
      eventIdentifier: eventIdentifier,
      externalIdentifier: externalIdentifier,
      lastModifiedDate: event.lastModifiedDate,
      title: title,
      location: location,
      latitude: latitude,
      longitude: longitude,
      temporal: temporal,
      availability: Self.availability(for: event),
      recurrence: recurrence,
      calendarTitle: calendarTitle
    )
  }

  private static func temporal(
    for event: EKEvent,
    startDate: Date,
    endDate: Date,
    calendar: Calendar
  ) -> CalendarEventTime {
    if event.isAllDay {
      let start = CalendarCivilDate(startDate, calendar: calendar)
      var endExclusive = CalendarCivilDate(endDate, calendar: calendar)
      // EventKit feeds can report an inclusive final day (or the same midnight
      // for a one-day event). Normalize both forms before the pure core rejects
      // the range as empty.
      if endExclusive <= start {
        endExclusive = start.adding(days: 1)!
      }
      return .allDay(
        start: start,
        endExclusive: endExclusive)
    }
    if let timeZone = event.timeZone {
      return .absolute(start: startDate, end: endDate, timeZone: timeZone)
    }
    return .floating(
      start: CalendarCivilDateTime(startDate, calendar: calendar),
      end: CalendarCivilDateTime(endDate, calendar: calendar))
  }

  private static func availability(for event: EKEvent) -> CalendarEventAvailability {
    switch event.availability {
    case .busy: .busy
    case .free: .free
    case .tentative: .tentative
    case .unavailable: .unavailable
    case .notSupported: .notSupported
    @unknown default: .notSupported
    }
  }

  private static func recurrence(
    for event: EKEvent,
    temporal: CalendarEventTime,
    calendar: Calendar
  ) -> CalendarEventRecurrence? {
    guard event.hasRecurrenceRules || event.isDetached else { return nil }
    guard let occurrenceDate = event.occurrenceDate else { return nil }
    let originalOccurrence: CalendarOccurrenceAnchor = switch temporal {
    case .absolute:
      .absolute(occurrenceDate)
    case .floating:
      .floating(CalendarCivilDateTime(occurrenceDate, calendar: calendar))
    case .allDay:
      .allDay(CalendarCivilDate(occurrenceDate, calendar: calendar))
    }
    return CalendarEventRecurrence(
      originalOccurrence: originalOccurrence,
      isDetached: event.isDetached)
  }
}

/// Injectable, read-only EventKit boundary for M7. It requests full event access
/// and queries all visible calendars in a trip's supplied interval. It contains no
/// closure that can create, update, or delete a Calendar event.
struct CalendarIngestionClient: Sendable {
  var requestFullAccess: @Sendable () async throws -> Bool
  var hasFullAccess: @Sendable () -> Bool
  var calendars: @Sendable () -> [CalendarSource]
  var events: @Sendable (_ interval: DateInterval, _ calendarIDs: Set<String>) throws -> [CalendarObservedEvent]
  /// Looks up one already-linked local EventKit event without treating a nil
  /// result as deletion by itself. This supports reporting a move beyond the trip
  /// window and is one input to the stronger constraint-deletion check below.
  var event: @Sendable (_ identifier: String) -> CalendarObservedEvent?
  /// Re-resolves a server identity when EventKit replaced its device-local ID.
  /// Snapshot conversion can fail for unusual recurring-series records, so raw
  /// item existence below remains the final conservative deletion guard.
  var eventsWithExternalIdentifier: @Sendable (_ identifier: String) -> [CalendarObservedEvent]
  /// Whether EventKit still contains any item with a server identity. Only false
  /// after a healthy full-access read corroborates Calendar-originated deletion.
  var hasCalendarItemsWithExternalIdentifier: @Sendable (_ identifier: String) -> Bool
}

extension CalendarIngestionClient: DependencyKey {
  static let liveValue: CalendarIngestionClient = {
    let box = EventKitStore()
    return CalendarIngestionClient(
      requestFullAccess: {
        try await box.store.requestFullAccessToEvents()
      },
      hasFullAccess: {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
      },
      calendars: {
        box.store.calendars(for: .event).map {
          CalendarSource(id: $0.calendarIdentifier, title: $0.title)
        }
      },
      events: { interval, calendarIDs in
        let calendars = box.store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        let predicate = box.store.predicateForEvents(
          withStart: interval.start, end: interval.end, calendars: calendars)
        return box.store.events(matching: predicate).compactMap(CalendarObservedEvent.init(event:))
      },
      event: { identifier in
        let event = box.store.event(withIdentifier: identifier)
          ?? (box.store.calendarItem(withIdentifier: identifier) as? EKEvent)
        return event.flatMap(CalendarObservedEvent.init(event:))
      },
      eventsWithExternalIdentifier: { identifier in
        box.store.calendarItems(withExternalIdentifier: identifier)
          .compactMap { $0 as? EKEvent }
          .compactMap(CalendarObservedEvent.init(event:))
      },
      hasCalendarItemsWithExternalIdentifier: { identifier in
        !box.store.calendarItems(withExternalIdentifier: identifier).isEmpty
      }
    )
  }()

  static let testValue = CalendarIngestionClient(
    requestFullAccess: { true },
    hasFullAccess: { true },
    calendars: { [] },
    events: { _, _ in [] },
    event: { _ in nil },
    eventsWithExternalIdentifier: { _ in [] },
    hasCalendarItemsWithExternalIdentifier: { _ in false }
  )
}

/// A device-local EventKit calendar. Its identifier must never sync: EventKit
/// identifiers describe one device's account configuration, not shared domain
/// state.
struct CalendarSource: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
}

/// The chosen Calendar source for reconciliation. This is a privacy/control
/// boundary local to the device, analogous to an EventKit binding — the shared
/// trip graph never learns which accounts a device can see.
struct CalendarSelectionStore: Sendable {
  var calendarID: @Sendable () -> String?
  var setCalendarID: @Sendable (_ id: String?) -> Void
}

private final class CalendarSelectionDefaults: @unchecked Sendable {
  let defaults = UserDefaults.standard
}

extension CalendarSelectionStore: DependencyKey {
  static let liveValue: CalendarSelectionStore = {
    let box = CalendarSelectionDefaults()
    return CalendarSelectionStore(
      calendarID: { box.defaults.string(forKey: "calendarReconciliationCalendarID") },
      setCalendarID: { id in box.defaults.set(id, forKey: "calendarReconciliationCalendarID") })
  }()

  static let testValue = CalendarSelectionStore(calendarID: { nil }, setCalendarID: { _ in })
}

extension DependencyValues {
  var calendarSelectionStore: CalendarSelectionStore {
    get { self[CalendarSelectionStore.self] }
    set { self[CalendarSelectionStore.self] = newValue }
  }
}

extension DependencyValues {
  var calendarIngestionClient: CalendarIngestionClient {
    get { self[CalendarIngestionClient.self] }
    set { self[CalendarIngestionClient.self] = newValue }
  }
}
