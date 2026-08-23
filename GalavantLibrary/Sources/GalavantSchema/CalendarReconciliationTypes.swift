import Foundation

/// A value snapshot of an EventKit event. The EventKit adapter lives in the app
/// target; the reconciliation core receives only this portable, read-only shape.
public struct CalendarObservedEvent: Equatable, Sendable, Identifiable {
  public let id: String
  /// Whether `id` is backed by an EventKit identifier rather than the display
  /// fallback used for incomplete subscribed events. A fallback can change when
  /// the event changes, so it may be shown but must never establish a link.
  public var hasStableLocalIdentity: Bool
  /// EventKit does not guarantee this for every subscribed/shared event. It is
  /// useful while observing locally, but never becomes a synced binding.
  public var eventIdentifier: String?
  /// A server-provided identity for the calendar item. Unlike `eventIdentifier`,
  /// this can identify the same event across devices. It is never persisted
  /// directly; Slice 3 hashes it into a shared outcome fingerprint.
  public var externalIdentifier: String?
  /// The source's revision instant when EventKit provides one. This is input to
  /// the semantic fingerprint, never a device-observation timestamp.
  public var lastModifiedDate: Date?
  public var title: String
  public var location: String?
  /// Calendar's human-authored notes. These become shared when the event is
  /// materialized as a Calendar-originated constraint or linked stop detail.
  public var notes: String?
  public var latitude: Double?
  public var longitude: Double?
  /// Zoned instant, floating civil time, or all-day civil range. This is captured
  /// at the EventKit boundary before a later device-zone change can alter meaning.
  public var temporal: CalendarEventTime
  public var availability: CalendarEventAvailability
  /// Nil for a standalone event. Recurring values identify exactly one occurrence
  /// by its original scheduled start, including a detached/moved occurrence.
  public var recurrence: CalendarEventRecurrence?
  public var calendarTitle: String

  public var isAllDay: Bool {
    if case .allDay = temporal { true } else { false }
  }

  public var isRecurring: Bool { recurrence != nil }

  public init(
    id: String,
    hasStableLocalIdentity: Bool = true,
    eventIdentifier: String? = nil,
    externalIdentifier: String? = nil,
    lastModifiedDate: Date? = nil,
    title: String,
    location: String? = nil,
    notes: String? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil,
    temporal: CalendarEventTime,
    availability: CalendarEventAvailability = .notSupported,
    recurrence: CalendarEventRecurrence? = nil,
    calendarTitle: String
  ) {
    self.id = id
    self.hasStableLocalIdentity = hasStableLocalIdentity
    self.eventIdentifier = eventIdentifier
    self.externalIdentifier = externalIdentifier
    self.lastModifiedDate = lastModifiedDate
    self.title = title
    self.location = location
    self.notes = notes
    self.latitude = latitude
    self.longitude = longitude
    self.temporal = temporal
    self.availability = availability
    self.recurrence = recurrence
    self.calendarTitle = calendarTitle
  }

  /// Compatibility initializer for ordinary timed Slice 1–3 call sites. EventKit
  /// itself uses the explicit temporal initializer above.
  public init(
    id: String,
    hasStableLocalIdentity: Bool = true,
    eventIdentifier: String? = nil,
    externalIdentifier: String? = nil,
    lastModifiedDate: Date? = nil,
    title: String,
    location: String? = nil,
    notes: String? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil,
    startDate: Date,
    endDate: Date,
    isAllDay: Bool,
    isRecurring: Bool = false,
    calendarTitle: String,
    calendar: Calendar = .current,
    availability: CalendarEventAvailability = .notSupported
  ) {
    let temporal: CalendarEventTime
    if isAllDay {
      let start = CalendarCivilDate(startDate, calendar: calendar)
      var end = CalendarCivilDate(endDate, calendar: calendar)
      if end <= start {
        let next = calendar.date(byAdding: .day, value: 1, to: startDate)!
        end = CalendarCivilDate(next, calendar: calendar)
      }
      temporal = .allDay(start: start, endExclusive: end)
    } else {
      temporal = .absolute(start: startDate, end: endDate, timeZone: calendar.timeZone)
    }
    let recurrence: CalendarEventRecurrence? = if isRecurring {
      CalendarEventRecurrence(
        originalOccurrence: isAllDay
          ? .allDay(CalendarCivilDate(startDate, calendar: calendar))
          : .absolute(startDate),
        isDetached: false)
    } else {
      nil
    }
    self.init(
      id: id,
      hasStableLocalIdentity: hasStableLocalIdentity,
      eventIdentifier: eventIdentifier,
      externalIdentifier: externalIdentifier,
      lastModifiedDate: lastModifiedDate,
      title: title,
      location: location,
      notes: notes,
      latitude: latitude,
      longitude: longitude,
      temporal: temporal,
      availability: availability,
      recurrence: recurrence,
      calendarTitle: calendarTitle)
  }

  /// A deterministic materialization used only by legacy I/O code that needs an
  /// absolute query value. Domain logic consumes `temporal` directly.
  public var startDate: Date {
    switch temporal {
    case let .absolute(start, _, _):
      start
    case let .floating(start, _):
      start.instant(in: TimeZone(secondsFromGMT: 0)!)!
    case let .allDay(start, _):
      start.date(in: TimeZone(secondsFromGMT: 0)!)!
    }
  }

  public var endDate: Date {
    switch temporal {
    case let .absolute(_, end, _):
      end
    case let .floating(_, end):
      end.instant(in: TimeZone(secondsFromGMT: 0)!)!
    case let .allDay(_, endExclusive):
      endExclusive.date(in: TimeZone(secondsFromGMT: 0)!)!
    }
  }

  /// The single gate deciding whether this event may drive a *shared* itinerary
  /// write and a shared ledger row. Slice 3 only promotes a change it can prove a
  /// second device derives identically from the same shared calendar:
  ///
  /// - `externalIdentifier != nil` — a server identity from a shared iCloud/CalDAV
  ///   source. The EventKit adapter withholds this for local, birthday, Exchange,
  ///   and subscribed sources, whose IDs are device- or platform-specific.
  /// - a recurring event carries an original-occurrence anchor, making its identity
  ///   independent of both the series and a detached occurrence's moved start.
  /// - its temporal range is valid. All-day, floating, and cross-day timed events
  ///   are first-class rather than being flattened through `Calendar.current`.
  public var isEligibleForSharedReconciliation: Bool {
    externalIdentifier != nil
      && CalendarCommitment(event: self) != nil
  }

  public var sharedReconciliationIneligibilityReason: String? {
    if externalIdentifier == nil {
      return "This event has no shared Calendar identity."
    }
    if CalendarCommitment(event: self) == nil {
      return "This event has invalid or incomplete timing."
    }
    return nil
  }
}
/// Why the read-only reconciliation view found a candidate. These cases are
/// intentionally descriptive rather than a numeric score: Slice 1 proves a
/// conservative ladder before later slices establish durable links.
public enum CalendarMatchBasis: Equatable, Sendable {
  /// The event and exactly one scheduled pool idea share a Maps place identity.
  case mapItemIdentifier
  /// Exactly one same-day stop has the same normalized visible name.
  case exactName
  /// A same-day event and stop are close together and share a meaningful name token,
  /// but Maps resolved them to different place records. This is review-only evidence.
  case nameAndProximity
}

/// One event's local reconciliation result. Slice 1 never applies this result;
/// it merely makes the ladder inspectable on the device that observed it.
public enum CalendarReconciliationResult: Equatable, Sendable {
  /// Strong enough to link automatically once Slice 2 adds durable authority.
  case automatic(ResolvedStop, basis: CalendarMatchBasis)
  /// Plausible, but requires later human resolution before it could establish a link.
  case proposed(ResolvedStop, basis: CalendarMatchBasis)
  /// More than one same-day stop has the same normalized name.
  case ambiguous([ResolvedStop])
  /// The event is an absolute instant, but no itinerary/day zone could be
  /// resolved safely from its travel context.
  case unresolvedTimeZone
  case unmatched
}

public struct CalendarReconciliationCandidate: Equatable, Sendable, Identifiable {
  public var input: CalendarIngestedEvent
  public var result: CalendarReconciliationResult
  public var projection: CalendarTripDayProjection
  public var temporalContext: CalendarTripTemporalContext?

  public var id: String { input.id }

  public init(
    input: CalendarIngestedEvent,
    result: CalendarReconciliationResult,
    projection: CalendarTripDayProjection,
    temporalContext: CalendarTripTemporalContext?
  ) {
    self.input = input
    self.result = result
    self.projection = projection
    self.temporalContext = temporalContext
  }

  public func projection(using fallbackTimeZone: TimeZone?) -> CalendarTripDayProjection {
    guard let temporalContext else { return .outsideTrip }
    return temporalContext.project(
      input.event.temporal,
      absoluteTimeZone: input.itineraryTimeZone ?? fallbackTimeZone)
  }
}
