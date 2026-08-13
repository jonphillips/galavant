import Foundation

extension CalendarReconciliation {
  /// Builds the shared-state changes for Calendar events that have no itinerary
  /// concept to reconcile with. Existing stop bindings always win, and ambiguous
  /// proposals remain human decisions rather than becoming duplicate constraints.
  ///
  /// `deletedEventIDs` are events a healthy full-access read confirmed gone: their
  /// shared row *and* device-local binding are removed (§6). `movedOutsideEventIDs`
  /// are events confirmed present but projected outside the trip window: the shared
  /// row is removed because it is no longer a current trip constraint, yet the
  /// binding is retained so the same deterministic constraint reappears if the event
  /// moves back in (§10 — moved is never a destructive delete of the concept).
  public static func constraintPlan(
    candidates: [CalendarReconciliationCandidate],
    tripID: Trip.ID,
    calendarID: String,
    localState: CalendarReconciliationLocalState,
    deletedEventIDs: Set<String> = [],
    movedOutsideEventIDs: Set<String> = [],
    regionTimeZone: TimeZone? = nil
  ) -> CalendarConstraintAutomaticPlan {
    var state = localState
    var upserts: [CalendarTripConstraint] = []
    var deletions: [CalendarTripConstraint.ID] = []

    for candidate in candidates {
      let event = candidate.input.event
      guard event.isEligibleForSharedReconciliation,
        event.hasStableLocalIdentity,
        let sourceExternalIdentifier = event.externalIdentifier
      else { continue }

      let bindingIndex = state.linkedConstraints.firstIndex { $0.matches(event) }
      if state.linkedStops.contains(where: { matches(event, linkedStop: $0) }) {
        if let bindingIndex {
          deletions.append(state.linkedConstraints.remove(at: bindingIndex).constraintID)
        }
        continue
      }

      if bindingIndex == nil {
        guard case .unmatched = candidate.result else { continue }
      }
      guard let constraint = CalendarTripConstraint(
          tripID: tripID,
          event: event,
          projection: candidate.projection)
      else { continue }

      let binding = CalendarLinkedConstraint(
        constraintID: constraint.id,
        eventID: event.id,
        calendarID: calendarID,
        sourceExternalIdentifier: sourceExternalIdentifier,
        occurrenceAnchor: event.recurrence?.originalOccurrence)
      if let bindingIndex {
        state.linkedConstraints[bindingIndex] = binding
      } else {
        state.linkedConstraints.append(binding)
      }
      upserts.append(constraint)

      // Supersede a stale binding for the *same* recurring slot under a different
      // identity. Converting a series between all-day and timed (or changing its
      // zone) re-keys the occurrence anchor, so the same commitment reappears with a
      // new constraint id; the old row would otherwise orphan forever — its series
      // still exists, so no per-event deletion evidence (§6) ever arrives. The server
      // `externalIdentifier` is stable across such edits and `occurrenceDate` keeps
      // the original scheduled day, so (series + trip day) names the slot regardless
      // of time mode. A sub-daily series with two occurrences on one trip day is the
      // one case this over-collapses; not a shape a household calendar produces.
      if let context = candidate.temporalContext, let newDay = candidate.projection.dayNumber {
        let absoluteTimeZone = candidate.projection.timeZone ?? regionTimeZone
        state.linkedConstraints.removeAll { existing in
          guard existing.constraintID != constraint.id,
            existing.calendarID == calendarID,
            existing.sourceExternalIdentifier == sourceExternalIdentifier,
            let anchor = existing.occurrenceAnchor,
            occurrenceDay(
              anchor,
              temporalContext: context,
              absoluteTimeZone: absoluteTimeZone) == newDay
          else { return false }
          deletions.append(existing.constraintID)
          return true
        }
      }
    }

    state.linkedConstraints.removeAll { binding in
      guard binding.calendarID == calendarID,
        deletedEventIDs.contains(binding.eventID)
      else { return false }
      deletions.append(binding.constraintID)
      return true
    }

    // A binding whose event is confirmed present but outside the trip window is no
    // longer a current trip constraint: drop its shared row while keeping the
    // binding, so a move back in re-creates the same deterministic constraint. An
    // event freshly upserted above is in-window by definition, so it is never both.
    let upsertedIDs = Set(upserts.map(\.id))
    for binding in state.linkedConstraints
    where binding.calendarID == calendarID
      && movedOutsideEventIDs.contains(binding.eventID)
      && !upsertedIDs.contains(binding.constraintID) {
      deletions.append(binding.constraintID)
    }

    var seenDeletionIDs: Set<CalendarTripConstraint.ID> = []
    let uniqueDeletions = deletions.filter { seenDeletionIDs.insert($0).inserted }
    return CalendarConstraintAutomaticPlan(
      upserts: upserts,
      deletions: uniqueDeletions,
      localState: state)
  }

  /// The trip day of a recurring occurrence's original scheduled slot, independent
  /// of whether it is currently represented as all-day, floating, or timed. Used to
  /// recognize that a re-keyed occurrence still names the same slot.
  private static func occurrenceDay(
    _ anchor: CalendarOccurrenceAnchor,
    temporalContext: CalendarTripTemporalContext,
    absoluteTimeZone: TimeZone?
  ) -> DayNumber? {
    let temporal: CalendarEventTime
    switch anchor {
    case let .allDay(day):
      guard let endExclusive = day.adding(days: 1) else { return nil }
      temporal = .allDay(start: day, endExclusive: endExclusive)
    case let .floating(dateTime):
      temporal = .floating(start: dateTime, end: dateTime)
    case let .absolute(date):
      guard let absoluteTimeZone else { return nil }
      temporal = .absolute(start: date, end: date, timeZone: absoluteTimeZone)
    }
    return temporalContext.project(temporal, absoluteTimeZone: absoluteTimeZone).dayNumber
  }

  private static func matches(
    _ event: CalendarObservedEvent,
    linkedStop: CalendarLinkedStop
  ) -> Bool {
    linkedStop.eventID == event.id
      || (linkedStop.sourceExternalIdentifier == event.externalIdentifier
        && linkedStop.occurrenceAnchor == event.recurrence?.originalOccurrence)
  }
}
