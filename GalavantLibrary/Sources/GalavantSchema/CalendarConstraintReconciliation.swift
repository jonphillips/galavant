import Foundation

extension CalendarReconciliation {
  /// Builds the shared-state changes for Calendar events that have no itinerary
  /// concept to reconcile with. Existing stop bindings always win, and ambiguous
  /// proposals remain human decisions rather than becoming duplicate constraints.
  public static func constraintPlan(
    candidates: [CalendarReconciliationCandidate],
    tripID: Trip.ID,
    calendarID: String,
    localState: CalendarReconciliationLocalState,
    deletedEventIDs: Set<String> = []
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
    }

    state.linkedConstraints.removeAll { binding in
      guard binding.calendarID == calendarID,
        deletedEventIDs.contains(binding.eventID)
      else { return false }
      deletions.append(binding.constraintID)
      return true
    }

    var seenDeletionIDs: Set<CalendarTripConstraint.ID> = []
    let uniqueDeletions = deletions.filter { seenDeletionIDs.insert($0).inserted }
    return CalendarConstraintAutomaticPlan(
      upserts: upserts,
      deletions: uniqueDeletions,
      localState: state)
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
