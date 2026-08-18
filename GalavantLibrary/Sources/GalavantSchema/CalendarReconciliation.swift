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

/// The pure, deliberately conservative first reconciliation ladder. It scopes
/// comparisons to the event's trip day, because a matching restaurant name on a
/// different day is not evidence that the event is the same commitment.
public enum CalendarReconciliation {
  public static func candidates(
    for events: [CalendarIngestedEvent],
    trip: Trip,
    plan: TripPlan,
    temporalContext: CalendarTripTemporalContext? = nil,
    ignoredSourceIdentityHashes: Set<String> = []
  ) -> [CalendarReconciliationCandidate] {
    let context = temporalContext ?? trip.startDate.flatMap {
      CalendarTripTemporalContext(
        tripStart: CalendarCivilDate($0, calendar: .current),
        dayCount: trip.lengthInDays)
    }
    return events.compactMap { event in
      if let source = CalendarReconciliationFingerprint.constraintSource(for: event.event),
        ignoredSourceIdentityHashes.contains(source)
      {
        return nil
      }
      let projection = context?.project(
        event.event.temporal,
        absoluteTimeZone: context?.assignmentTimeZone ?? event.itineraryTimeZone) ?? .outsideTrip
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
        tripStart: CalendarCivilDate(startDate, calendar: .current), dayCount: trip.lengthInDays)
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
      return projection == .unresolvedTimeZone && hasPotentialMatchWithoutDay(input, plan: plan)
        ? .unresolvedTimeZone
        : .unmatched
    }
    let stops = plan.itinerary.first(where: { $0.number == dayNumber })?.stops ?? []

    let mapMatches: [ResolvedStop]
    if let mapItemIdentifier = input.matchedPlace?.mapItemIdentifier {
      mapMatches = stops.filter { $0.idea?.mapItemIdentifier == mapItemIdentifier }
      if mapMatches.count == 1, let match = mapMatches.first {
        return .automatic(match, basis: .mapItemIdentifier)
      }
      if mapMatches.count > 1 { return .ambiguous(mapMatches) }
    } else {
      mapMatches = []
    }

    let names = Set([
      input.matchedPlace.map { normalizedName($0.name) },
      normalizedName(input.event.title),
    ].compactMap { $0 }).filter { !$0.isEmpty }
    guard !names.isEmpty else { return .unmatched }
    let matches = stops.filter { names.contains(normalizedName($0.content.title)) }
    if matches.count == 1, let match = matches.first {
      // A map-identity candidate would already have returned above; one exact
      // same-day name is therefore the unambiguous automatic rung.
      return .automatic(match, basis: .exactName)
    }
    if matches.count > 1 { return .ambiguous(matches) }

    let nearbyNameMatches = stops.filter { sharesMeaningfulNameToken(input, stop: $0) && isNearby(input, stop: $0) }
    if nearbyNameMatches.count == 1, let match = nearbyNameMatches.first {
      return .proposed(match, basis: .nameAndProximity)
    }
    if nearbyNameMatches.count > 1 { return .ambiguous(nearbyNameMatches) }
    return .unmatched
  }

  /// A missing travel zone only needs review when the event otherwise resembles
  /// an itinerary stop. Location-less commitments remain visible as unmatched
  /// rather than asking the user to resolve a zone the app cannot infer.
  private static func hasPotentialMatchWithoutDay(
    _ input: CalendarIngestedEvent,
    plan: TripPlan
  ) -> Bool {
    let stops = plan.itinerary.flatMap(\.stops)
    if let mapItemIdentifier = input.matchedPlace?.mapItemIdentifier,
      stops.contains(where: { $0.idea?.mapItemIdentifier == mapItemIdentifier })
    {
      return true
    }
    let names = Set([
      input.matchedPlace.map { normalizedName($0.name) },
      normalizedName(input.event.title),
    ].compactMap { $0 }).filter { !$0.isEmpty }
    return !names.isEmpty && stops.contains { names.contains(normalizedName($0.content.title)) }
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
    makeHistoryID: () -> UUID,
    manuallyRelinkedSourceFingerprint: String? = nil
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
        !state.linkedStops.contains(where: { $0.stopID == stop.id }),
        manuallyRelinkedSourceFingerprint == CalendarReconciliationFingerprint.source(for: event)
          || !hasMostRecentUnlink(for: event, in: state.history)
      else { continue }

      state.linkedStops.append(
        CalendarLinkedStop(
          stopID: stop.id,
          eventID: event.id,
          commitment: commitment,
          observedAt: observedAt,
          eventTitle: event.title,
          eventNotes: event.notes,
          sourceExternalIdentifier: event.externalIdentifier,
          occurrenceAnchor: event.recurrence?.originalOccurrence,
          itineraryTimeZoneIdentifier: timeZone?.identifier))
      state.history.append(historyEntry(
        kind: .linked, stopID: stop.id, eventID: event.id, event: event,
        current: commitment, observedAt: observedAt, makeID: makeHistoryID))
      applications.append(
        CalendarReconciliationApplication(
          stopID: stop.id, commitment: commitment,
          dayNumber: day, kind: .linked,
          sourceFingerprint: CalendarReconciliationFingerprint.source(for: event),
          eventTitle: event.title,
          calendarNotes: event.notes))
    }

    recordOutsideTripObservations(
      outsideTripObservations, in: &state,
      observedAt: observedAt, makeHistoryID: makeHistoryID)

    return CalendarReconciliationAutomaticPlan(applications: applications, localState: state)
  }

  /// Promotes a human-confirmed proposal through the exact same application path
  /// as an automatic match. The eligibility, stable identity, and one-event/one-stop
  /// gates therefore remain in one place.
  public static func manualLinkPlan(
    candidate: CalendarReconciliationCandidate,
    stop: ResolvedStop,
    localState: CalendarReconciliationLocalState,
    observedAt: Date,
    makeHistoryID: () -> UUID
  ) -> CalendarReconciliationAutomaticPlan {
    let linked = manuallyLinkedCandidate(candidate, to: stop)
    return automaticPlan(
      candidates: [linked], localState: localState, observedAt: observedAt,
      makeHistoryID: makeHistoryID,
      manuallyRelinkedSourceFingerprint: CalendarReconciliationFingerprint.source(
        for: candidate.input.event))
  }

  /// Converts a human-selected proposal into the same automatic result used by
  /// the durable manual-link path. The app can use this during cache-only
  /// reconciliation without rereading or re-ingesting Calendar.
  public static func manuallyLinkedCandidate(
    _ candidate: CalendarReconciliationCandidate,
    to stop: ResolvedStop
  ) -> CalendarReconciliationCandidate {
    var linked = candidate
    let basis: CalendarMatchBasis = switch candidate.result {
    case let .automatic(_, basis), let .proposed(_, basis): basis
    case .ambiguous: .exactName
    case .unresolvedTimeZone, .unmatched: .exactName
    }
    linked.result = .automatic(stop, basis: basis)
    return linked
  }

  /// Finds the ingested candidate represented by a shared constraint. The
  /// constraint stores only the stable source fingerprint, so this lookup keeps
  /// the app-side EventKit identity out of the shared domain model.
  public static func candidate(
    for constraint: CalendarTripConstraint,
    in candidates: [CalendarReconciliationCandidate]
  ) -> CalendarReconciliationCandidate? {
    candidates.first {
      CalendarReconciliationFingerprint.constraintSource(for: $0.input.event)
        == constraint.sourceIdentityHash
    }
  }

  /// Removes a local EventKit binding and records the human correction. The shared
  /// itinerary pin is cleared by the app shell in the same user action.
  public static func unlinkPlan(
    candidate: CalendarReconciliationCandidate,
    localState: CalendarReconciliationLocalState,
    observedAt: Date,
    makeHistoryID: () -> UUID
  ) -> CalendarReconciliationUnlinkPlan? {
    guard let index = linkedStopIndex(for: candidate.input.event, in: localState.linkedStops) else {
      return nil
    }
    var state = localState
    let linked = state.linkedStops.remove(at: index)
    state.history.append(
      CalendarReconciliationHistoryEntry(
        id: makeHistoryID(), kind: .unlinked, stopID: linked.stopID,
        eventID: candidate.input.event.id, eventTitle: candidate.input.event.title,
        current: linked.commitment,
        sourceFingerprint: CalendarReconciliationFingerprint.source(for: candidate.input.event),
        appliedAt: observedAt))
    return CalendarReconciliationUnlinkPlan(stopID: linked.stopID, localState: state)
  }

  /// Removes Calendar authority after a linked event is authoritatively deleted.
  /// The app shell clears the Calendar-derived clock while retaining the real
  /// idea-backed stop as an ordinary, unbooked plan.
  public static func deletedLinkedStopsPlan(
    localState: CalendarReconciliationLocalState,
    deletedEventIDs: Set<String>,
    observedAt: Date,
    makeHistoryID: () -> UUID
  ) -> CalendarReconciliationDeletedLinkedStopsPlan {
    var state = localState
    let deleted = state.linkedStops.filter { deletedEventIDs.contains($0.eventID) }
    state.linkedStops.removeAll { deletedEventIDs.contains($0.eventID) }
    for linked in deleted {
      let sourceFingerprint = state.history.last(where: { $0.stopID == linked.stopID })?.sourceFingerprint
      state.history.append(
        CalendarReconciliationHistoryEntry(
          id: makeHistoryID(), kind: .unlinked, stopID: linked.stopID,
          eventID: linked.eventID, eventTitle: linked.eventTitle ?? "Calendar event",
          current: linked.commitment, sourceFingerprint: sourceFingerprint,
          appliedAt: observedAt))
    }
    return CalendarReconciliationDeletedLinkedStopsPlan(
      stopIDs: deleted.map(\.stopID), localState: state)
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
    let notesChanged = linked.eventNotes != event.notes
    let metadataChanged = linked.sourceExternalIdentifier != event.externalIdentifier
      || linked.occurrenceAnchor != event.recurrence?.originalOccurrence
      || (linked.itineraryTimeZoneIdentifier == nil && timeZone != nil)
    guard identityChanged || commitmentChanged || notesChanged || metadataChanged else { return nil }
    state.linkedStops[index] = CalendarLinkedStop(
      stopID: linked.stopID,
      eventID: event.id,
      commitment: commitment,
      observedAt: observedAt,
      eventTitle: event.title,
      eventNotes: event.notes,
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
    guard linked.commitment != commitment || notesChanged else { return nil }
    return CalendarReconciliationApplication(
      stopID: linked.stopID, commitment: commitment,
      dayNumber: day, kind: .updated,
      sourceFingerprint: CalendarReconciliationFingerprint.source(for: event),
      eventTitle: event.title,
      calendarNotes: event.notes)
  }

  private static func hasMostRecentUnlink(
    for event: CalendarObservedEvent,
    in history: [CalendarReconciliationHistoryEntry]
  ) -> Bool {
    guard let sourceFingerprint = CalendarReconciliationFingerprint.source(for: event) else {
      return false
    }
    return history
      .filter { $0.sourceFingerprint == sourceFingerprint }
      .max { lhs, rhs in lhs.appliedAt < rhs.appliedAt }?
      .kind == .unlinked
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

  public static func linkedStopIndex(
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

}
