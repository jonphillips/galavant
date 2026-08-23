import Foundation

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
          id: makeHistoryID(), kind: .commitmentDeleted, stopID: linked.stopID,
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
