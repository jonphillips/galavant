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

/// The pure, deliberately conservative first reconciliation ladder. It scopes
/// comparisons to the event's trip day, because a matching restaurant name on a
/// different day is not evidence that the event is the same commitment.
public enum CalendarReconciliation {
  public static func candidates(
    for events: [CalendarIngestedEvent], trip: Trip, plan: TripPlan
  ) -> [CalendarReconciliationCandidate] {
    events.compactMap { event in
      let context = trip.startDate.flatMap {
        CalendarTripTemporalContext(startDate: $0, dayCount: trip.lengthInDays)
      }
      let projection = context?.project(
        event.event.temporal,
        absoluteTimeZone: event.itineraryTimeZone) ?? .outsideTrip
      guard projection != .outsideTrip else { return nil }
      return CalendarReconciliationCandidate(
        input: event,
        result: result(for: event, plan: plan, projection: projection),
        projection: projection,
        temporalContext: context)
    }
  }

  public static func result(
    for input: CalendarIngestedEvent, trip: Trip, plan: TripPlan
  ) -> CalendarReconciliationResult {
    guard let startDate = trip.startDate,
      let context = CalendarTripTemporalContext(
        startDate: startDate, dayCount: trip.lengthInDays)
    else { return .unmatched }
    let projection = context.project(
      input.event.temporal,
      absoluteTimeZone: input.itineraryTimeZone)
    return result(for: input, plan: plan, projection: projection)
  }

  private static func result(
    for input: CalendarIngestedEvent,
    plan: TripPlan,
    projection: CalendarTripDayProjection
  ) -> CalendarReconciliationResult {
    guard case let .day(dayNumber, _) = projection else {
      return projection == .unresolvedTimeZone ? .unresolvedTimeZone : .unmatched
    }
    let stops = plan.itinerary.first(where: { $0.number == dayNumber })?.stops ?? []

    if let mapItemIdentifier = input.matchedPlace?.mapItemIdentifier {
      let matches = stops.filter { $0.idea?.mapItemIdentifier == mapItemIdentifier }
      if matches.count == 1, let match = matches.first {
        return .automatic(match, basis: .mapItemIdentifier)
      }
      if matches.count > 1 { return .ambiguous(matches) }
    }

    let name = normalizedName(input.matchedPlace?.name ?? input.event.title)
    guard !name.isEmpty else { return .unmatched }
    let matches = stops.filter { normalizedName($0.content.title) == name }
    if matches.count == 1, let match = matches.first {
      return .proposed(match, basis: .exactName)
    }
    if matches.count > 1 { return .ambiguous(matches) }

    let nearbyNameMatches = stops.filter { sharesMeaningfulNameToken(input, stop: $0) && isNearby(input, stop: $0) }
    if nearbyNameMatches.count == 1, let match = nearbyNameMatches.first {
      return .proposed(match, basis: .nameAndProximity)
    }
    if nearbyNameMatches.count > 1 { return .ambiguous(nearbyNameMatches) }
    return .unmatched
  }

  /// The pure auto-apply pass for Slice 2. A previously linked event remains
  /// authoritative even if its day or title no longer produces a fresh matching
  /// candidate. Its local EventKit ID is primary evidence; a recurring occurrence
  /// can heal a changed ID using its server source plus original-occurrence anchor.
  /// New links require the Slice 1 automatic Maps-identity result and exactly one
  /// event for the target stop in this pass. An absent event produces no action —
  /// loss of visibility is never inferred as deletion.
  public static func automaticPlan(
    candidates: [CalendarReconciliationCandidate],
    outsideTripObservations: [CalendarBoundEventObservation] = [],
    localState: CalendarReconciliationLocalState,
    observedAt: Date,
    makeHistoryID: () -> UUID
  ) -> CalendarReconciliationAutomaticPlan {
    var state = localState
    var applications: [CalendarReconciliationApplication] = []
    let automaticStops = automaticStopCounts(candidates)

    for candidate in candidates {
      let event = candidate.input.event
      // The shared boundary: an event without server identity, a valid temporal
      // range, or a recurrence occurrence anchor remains visible but never binds,
      // writes the itinerary, or promotes a shared ledger row.
      guard event.isEligibleForSharedReconciliation else { continue }
      guard let commitment = CalendarCommitment(event: event) else { continue }

      if let index = linkedStopIndex(for: event, in: state.linkedStops) {
        if let application = updateLinkedStop(
          at: index,
          with: candidate,
          commitment: commitment,
          in: &state,
          observedAt: observedAt,
          makeHistoryID: makeHistoryID
        ) {
          applications.append(application)
        }
        continue
      }

      guard case let .automatic(stop, _) = candidate.result,
        case let .day(day, timeZone) = candidate.projection,
        event.hasStableLocalIdentity,
        automaticStops[stop.id] == 1,
        !state.linkedStops.contains(where: { $0.stopID == stop.id })
      else { continue }

      state.linkedStops.append(
        CalendarLinkedStop(
          stopID: stop.id,
          eventID: event.id,
          commitment: commitment,
          observedAt: observedAt,
          eventTitle: event.title,
          sourceExternalIdentifier: event.externalIdentifier,
          occurrenceAnchor: event.recurrence?.originalOccurrence,
          itineraryTimeZoneIdentifier: timeZone?.identifier))
      state.history.append(historyEntry(
        kind: .linked, stopID: stop.id, eventID: event.id, event: event,
        current: commitment, observedAt: observedAt, makeID: makeHistoryID))
      applications.append(
        CalendarReconciliationApplication(
          stopID: stop.id, commitment: commitment,
          dayNumber: day, kind: .linked))
    }

    recordOutsideTripObservations(
      outsideTripObservations, in: &state,
      observedAt: observedAt, makeHistoryID: makeHistoryID)

    return CalendarReconciliationAutomaticPlan(applications: applications, localState: state)
  }

  private static func updateLinkedStop(
    at index: Int,
    with candidate: CalendarReconciliationCandidate,
    commitment: CalendarCommitment,
    in state: inout CalendarReconciliationLocalState,
    observedAt: Date,
    makeHistoryID: () -> UUID
  ) -> CalendarReconciliationApplication? {
    let event = candidate.input.event
    let linked = state.linkedStops[index]
    let projection = candidate.projection(using: linked.itineraryTimeZone)
    guard case let .day(day, timeZone) = projection else { return nil }
    let identityChanged = linked.eventID != event.id
    let commitmentChanged = linked.commitment != commitment
      || linked.movedOutsideTripCommitment != nil
    let metadataChanged = linked.sourceExternalIdentifier != event.externalIdentifier
      || linked.occurrenceAnchor != event.recurrence?.originalOccurrence
      || (linked.itineraryTimeZoneIdentifier == nil && timeZone != nil)
    guard identityChanged || commitmentChanged || metadataChanged else { return nil }
    state.linkedStops[index] = CalendarLinkedStop(
      stopID: linked.stopID,
      eventID: event.id,
      commitment: commitment,
      observedAt: observedAt,
      eventTitle: event.title,
      sourceExternalIdentifier: event.externalIdentifier,
      occurrenceAnchor: event.recurrence?.originalOccurrence,
      itineraryTimeZoneIdentifier: timeZone?.identifier
        ?? linked.itineraryTimeZoneIdentifier)
    if commitmentChanged {
      state.history.append(historyEntry(
        kind: .updated, stopID: linked.stopID, eventID: event.id, event: event,
        previous: linked.movedOutsideTripCommitment ?? linked.commitment,
        current: commitment, observedAt: observedAt, makeID: makeHistoryID))
    }
    guard linked.commitment != commitment else { return nil }
    return CalendarReconciliationApplication(
      stopID: linked.stopID, commitment: commitment,
      dayNumber: day, kind: .updated)
  }

  private static func automaticStopCounts(
    _ candidates: [CalendarReconciliationCandidate]
  ) -> [TripIdea.ID: Int] {
    candidates.reduce(into: [:]) { counts, candidate in
      guard candidate.input.event.isEligibleForSharedReconciliation,
        case let .automatic(stop, _) = candidate.result
      else { return }
      counts[stop.id, default: 0] += 1
    }
  }

  private static func linkedStopIndex(
    for event: CalendarObservedEvent,
    in linkedStops: [CalendarLinkedStop]
  ) -> Int? {
    if let direct = linkedStops.firstIndex(where: { $0.eventID == event.id }) {
      return direct
    }
    guard event.hasStableLocalIdentity,
      let sourceExternalIdentifier = event.externalIdentifier,
      let occurrenceAnchor = event.recurrence?.originalOccurrence
    else { return nil }
    return linkedStops.firstIndex {
      $0.sourceExternalIdentifier == sourceExternalIdentifier
        && $0.occurrenceAnchor == occurrenceAnchor
    }
  }

  private static func recordOutsideTripObservations(
    _ observations: [CalendarBoundEventObservation],
    in state: inout CalendarReconciliationLocalState,
    observedAt: Date,
    makeHistoryID: () -> UUID
  ) {
    for observation in observations {
      let event = observation.event
      guard
        event.isEligibleForSharedReconciliation,
        let commitment = CalendarCommitment(event: event),
        let index = state.linkedStops.firstIndex(where: { $0.eventID == observation.bindingID })
          ?? linkedStopIndex(for: event, in: state.linkedStops)
      else { continue }

      let linked = state.linkedStops[index]
      guard linked.movedOutsideTripCommitment != commitment else { continue }
      state.linkedStops[index] = CalendarLinkedStop(
        stopID: linked.stopID, eventID: event.id, commitment: linked.commitment,
        observedAt: observedAt, eventTitle: event.title,
        movedOutsideTripCommitment: commitment,
        sourceExternalIdentifier: event.externalIdentifier,
        occurrenceAnchor: event.recurrence?.originalOccurrence,
        itineraryTimeZoneIdentifier: linked.itineraryTimeZoneIdentifier)
      state.history.append(historyEntry(
        kind: .movedOutsideTrip, stopID: linked.stopID, eventID: linked.eventID,
        event: event, previous: linked.commitment, current: commitment,
        observedAt: observedAt, makeID: makeHistoryID))
    }
  }

  private static func historyEntry(
    kind: CalendarReconciliationHistoryEntry.Kind,
    stopID: TripIdea.ID,
    eventID: String,
    event: CalendarObservedEvent,
    previous: CalendarCommitment? = nil,
    current: CalendarCommitment,
    observedAt: Date,
    makeID: () -> UUID
  ) -> CalendarReconciliationHistoryEntry {
    CalendarReconciliationHistoryEntry(
      id: makeID(), kind: kind, stopID: stopID, eventID: eventID, eventTitle: event.title,
      previous: previous, current: current,
      sourceFingerprint: CalendarReconciliationFingerprint.source(for: event),
      appliedAt: observedAt)
  }

  /// Comparison-only normalization: case/diacritic/punctuation differences in a
  /// Calendar title must not make one place appear unmatched. Empty names never
  /// match; they carry no place evidence.
  static func normalizedName(_ name: String) -> String {
    name
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .unicodeScalars
      .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
      .joined()
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  /// A title fragment is not enough: both sides must share a complete, meaningful
  /// token. This avoids raw-substring accidents such as `bar` matching `barcelona`.
  private static func sharesMeaningfulNameToken(
    _ input: CalendarIngestedEvent, stop: ResolvedStop
  ) -> Bool {
    let eventTokens = Set(normalizedName(input.matchedPlace?.name ?? input.event.title).split(separator: " "))
    let stopTokens = Set(normalizedName(stop.content.title).split(separator: " "))
    return eventTokens.intersection(stopTokens).contains { $0.count >= 4 }
  }

  /// A nearby, differently-resolved Maps record is enough to invite review but is
  /// intentionally not enough to create a Calendar binding. Coordinates must exist
  /// on both sides; absent location facts never turn name similarity into evidence.
  private static func isNearby(_ input: CalendarIngestedEvent, stop: ResolvedStop) -> Bool {
    guard
      let eventLatitude = input.event.latitude,
      let eventLongitude = input.event.longitude,
      let stopLatitude = stop.content.latitude,
      let stopLongitude = stop.content.longitude
    else { return false }

    return distanceInMeters(
      latitude1: eventLatitude,
      longitude1: eventLongitude,
      latitude2: stopLatitude,
      longitude2: stopLongitude) <= 100
  }

  private static func distanceInMeters(
    latitude1: Double,
    longitude1: Double,
    latitude2: Double,
    longitude2: Double
  ) -> Double {
    let latitudeDelta = (latitude2 - latitude1) * .pi / 180
    let longitudeDelta = (longitude2 - longitude1) * .pi / 180
    let haversine = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
      + cos(latitude1 * .pi / 180) * cos(latitude2 * .pi / 180)
      * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
    return 6_371_000 * 2 * atan2(sqrt(haversine), sqrt(1 - haversine))
  }
}
