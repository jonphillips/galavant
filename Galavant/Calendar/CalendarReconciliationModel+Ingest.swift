import Foundation
import GalavantSchema

extension CalendarReconciliationModel {
  struct IngestionCache {
    let tripID: Trip.ID
    let calendarID: String
    let contextFingerprint: CalendarReconciliationContextFingerprint
    let scope: CalendarTripScope
    let regionTimeZone: TimeZone?
    let tripCalendar: Calendar
    let temporalContext: CalendarTripTemporalContext
    let observedEvents: [CalendarObservedEvent]
    let ingestedEvents: [CalendarIngestedEvent]
  }

  func makeIngestionCache(
    trip: Trip,
    plan: TripPlan,
    scope: CalendarTripScope,
    queryInterval: DateInterval,
    selectedCalendarID: String,
    regionTimeZone: TimeZone?,
    tripCalendar: Calendar
  ) async throws -> IngestionCache {
    // Query two padded days on either side, then let the pure civil/absolute
    // scope discard the padding. Ignore state is deliberately not applied here:
    // cache the complete observed list so un-ignore can reconcile locally.
    let contextFingerprint = try await calendarContextFingerprint(for: trip, plan: plan)
    let observedEvents = try calendarClient.events(queryInterval, [selectedCalendarID]).filter {
      scope.overlaps($0.temporal, absoluteTimeZone: nil) != false
    }
    let temporalContext = CalendarTripTemporalContext(
      scope: scope,
      assignmentTimeZone: regionTimeZone,
      dayTimeZones: await dayTimeZones(for: trip, centroid: regionTimeZone))
    let ingestedEvents = try await ingest(observedEvents, regionTimeZone: regionTimeZone)
    return IngestionCache(
      tripID: trip.id,
      calendarID: selectedCalendarID,
      contextFingerprint: contextFingerprint,
      scope: scope,
      regionTimeZone: regionTimeZone,
      tripCalendar: tripCalendar,
      temporalContext: temporalContext,
      observedEvents: observedEvents,
      ingestedEvents: ingestedEvents)
  }

  func reconcileUsing(
    trip: Trip,
    plan: TripPlan,
    cache: IngestionCache,
    useEventKitEvidence: Bool,
    manualLink: (candidateID: String, stop: ResolvedStop)? = nil,
    historyStore: CalendarReconciliationHistoryStore,
    now: Date,
    uuid: @escaping () -> UUID,
    allIgnoredEvents: [CalendarIgnoredEvent],
    allCalendarConstraints: [CalendarTripConstraint]
  ) async throws {
    localState = historyStore.state(trip.id)
    let ignoredSourceIdentityHashes = ignoredSourceIdentityHashes(
      for: trip, in: allIgnoredEvents)
    let reconciledCandidates = reconciledCandidates(
      for: cache.ingestedEvents,
      trip: trip,
      plan: plan,
      temporalContext: cache.temporalContext,
      ignoredSourceIdentityHashes: ignoredSourceIdentityHashes,
      manualLink: manualLink)
    candidates = reconciledCandidates
    let outsideTripObservations = outsideTripObservations(in: cache, useEventKitEvidence: useEventKitEvidence)
    let deletedEventIDs = deletedEventIDs(
      in: cache, useEventKitEvidence: useEventKitEvidence)
    let deletedLinkedStopsPlan = CalendarReconciliation.deletedLinkedStopsPlan(
      localState: localState,
      deletedEventIDs: deletedEventIDs,
      observedAt: now,
      makeHistoryID: { uuid() })
    let automaticPlan = makeAutomaticPlan(
      candidates: reconciledCandidates,
      outsideTripObservations: outsideTripObservations,
      deletedLinkedStopsPlan: deletedLinkedStopsPlan,
      manualLink: manualLink,
      now: now,
      uuid: uuid)
    let previousDayNumbers = previousDayNumbers(for: plan)
    let ignoredEventIDsToReap = useEventKitEvidence
      ? ignoredEventIDsToReap(
        tripID: trip.id,
        deletedEventIDs: deletedEventIDs,
        allIgnoredEvents: allIgnoredEvents)
      : []
    let constraintPlan = makeConstraintPlan(
      candidates: reconciledCandidates,
      trip: trip,
      cache: cache,
      localState: automaticPlan.localState,
      deletedEventIDs: deletedEventIDs,
      ignoredSourceIdentityHashes: ignoredSourceIdentityHashes,
      useEventKitEvidence: useEventKitEvidence,
      allCalendarConstraints: allCalendarConstraints)
    let repairs = CalendarReconciliation.planRepairs(
      applications: automaticPlan.applications,
      previousDayNumbers: previousDayNumbers,
      history: constraintPlan.localState.history,
      tripID: trip.id)
    try await persist(
      automaticPlan,
      constraintPlan: constraintPlan,
      repairs: repairs,
      tripID: trip.id,
      historyStore: historyStore,
      deletedLinkedStopIDs: deletedLinkedStopsPlan.stopIDs,
      ignoredEventIDsToReap: ignoredEventIDsToReap)
    try await freezeIfNeeded(
      trip: trip,
      cache: cache,
      useEventKitEvidence: useEventKitEvidence,
      now: now)
  }

  private func ignoredSourceIdentityHashes(
    for trip: Trip,
    in allIgnoredEvents: [CalendarIgnoredEvent]
  ) -> Set<String> {
    Set(allIgnoredEvents.filter { $0.tripID == trip.id }.map(\.sourceIdentityHash))
  }

  private func reconciledCandidates(
    for events: [CalendarIngestedEvent],
    trip: Trip,
    plan: TripPlan,
    temporalContext: CalendarTripTemporalContext,
    ignoredSourceIdentityHashes: Set<String>,
    manualLink: (candidateID: String, stop: ResolvedStop)?
  ) -> [CalendarReconciliationCandidate] {
    var candidates = CalendarReconciliation.candidates(
      for: events,
      trip: trip,
      plan: plan,
      temporalContext: temporalContext,
      ignoredSourceIdentityHashes: ignoredSourceIdentityHashes)
    if let manualLink,
      let index = candidates.firstIndex(where: { $0.id == manualLink.candidateID })
    {
      candidates[index] = CalendarReconciliation.manuallyLinkedCandidate(
        candidates[index], to: manualLink.stop)
    }
    return candidates
  }

  private func outsideTripObservations(
    in cache: IngestionCache,
    useEventKitEvidence: Bool
  ) -> [CalendarBoundEventObservation] {
    guard useEventKitEvidence else { return [] }
    return localState.linkedStops.compactMap { linked in
      guard
        let event = calendarClient.event(linked.eventID),
        cache.temporalContext.project(
          event.temporal,
          absoluteTimeZone: linked.itineraryTimeZone) == .outsideTrip
      else { return nil }
      return CalendarBoundEventObservation(bindingID: linked.eventID, event: event)
    }
  }

  private func deletedEventIDs(
    in cache: IngestionCache,
    useEventKitEvidence: Bool
  ) -> Set<String> {
    guard useEventKitEvidence else { return [] }
    return deletedConstraintEventIDs(
      observedEvents: cache.observedEvents,
      selectedCalendarID: cache.calendarID)
  }

  private func makeAutomaticPlan(
    candidates: [CalendarReconciliationCandidate],
    outsideTripObservations: [CalendarBoundEventObservation],
    deletedLinkedStopsPlan: CalendarReconciliationDeletedLinkedStopsPlan,
    manualLink: (candidateID: String, stop: ResolvedStop)?,
    now: Date,
    uuid: @escaping () -> UUID
  ) -> CalendarReconciliationAutomaticPlan {
    CalendarReconciliation.automaticPlan(
      candidates: candidates,
      outsideTripObservations: outsideTripObservations,
      localState: deletedLinkedStopsPlan.localState,
      observedAt: now,
      makeHistoryID: { uuid() },
      manuallyRelinkedSourceFingerprint: manualLink.flatMap { manual in
        candidates
          .first(where: { $0.id == manual.candidateID })
          .flatMap { CalendarReconciliationFingerprint.source(for: $0.input.event) }
      })
  }

  private func previousDayNumbers(for plan: TripPlan) -> [TripIdea.ID: Int] {
    Dictionary(
      uniqueKeysWithValues: plan.entries.compactMap { entry in
        entry.dayNumber.map { (entry.id, $0) }
      })
  }

  private func makeConstraintPlan(
    candidates: [CalendarReconciliationCandidate],
    trip: Trip,
    cache: IngestionCache,
    localState: CalendarReconciliationLocalState,
    deletedEventIDs: Set<String>,
    ignoredSourceIdentityHashes: Set<String>,
    useEventKitEvidence: Bool,
    allCalendarConstraints: [CalendarTripConstraint]
  ) -> CalendarConstraintAutomaticPlan {
    CalendarReconciliation.constraintPlan(
      candidates: candidates,
      tripID: trip.id,
      calendarID: cache.calendarID,
      localState: localState,
      deletedEventIDs: deletedEventIDs,
      movedOutsideEventIDs: useEventKitEvidence
        ? movedOutsideConstraintEventIDs(
          selectedCalendarID: cache.calendarID,
          temporalContext: cache.temporalContext,
          regionTimeZone: cache.regionTimeZone)
        : [],
      regionTimeZone: cache.regionTimeZone,
      existingConstraints: allCalendarConstraints.filter { $0.tripID == trip.id },
      ignoredSourceIdentityHashes: ignoredSourceIdentityHashes)
  }

  private func freezeIfNeeded(
    trip: Trip,
    cache: IngestionCache,
    useEventKitEvidence: Bool,
    now: Date
  ) async throws {
    guard useEventKitEvidence, trip.isPast(at: now, calendar: cache.tripCalendar) else { return }
    let frozenAt = now
    try await database.write { db in
      try Trip.completeCalendarReconciliation(tripID: trip.id, frozenAt: frozenAt, in: db)
    }
  }

  private func persist(
    _ plan: CalendarReconciliationAutomaticPlan,
    constraintPlan: CalendarConstraintAutomaticPlan,
    repairs: [CalendarPlanRepair],
    tripID: Trip.ID,
    historyStore: CalendarReconciliationHistoryStore,
    deletedLinkedStopIDs: [TripIdea.ID] = [],
    ignoredEventIDsToReap: [CalendarIgnoredEvent.ID] = []
  ) async throws {
    let newHistory = constraintPlan.localState.history.dropFirst(localState.history.count)
    let ledgerEntries = newHistory.compactMap {
      CalendarReconciliationLedgerEntry(tripID: tripID, historyEntry: $0)
    }
    guard !plan.applications.isEmpty
      || !ledgerEntries.isEmpty
      || !constraintPlan.upserts.isEmpty
      || !constraintPlan.deletions.isEmpty
      || !deletedLinkedStopIDs.isEmpty
      || !ignoredEventIDsToReap.isEmpty
      || !repairs.isEmpty
    else {
      updateLocalStateIfNeeded(
        constraintPlan.localState, tripID: tripID, historyStore: historyStore)
      return
    }
    try await database.write { db in
      for application in plan.applications {
        try TripIdea.applyCalendarCommitment(
          application.commitment,
          stopID: application.stopID,
          dayNumber: application.dayNumber,
          calendarNotes: application.calendarNotes,
          in: db)
      }
      for entry in ledgerEntries {
        try CalendarReconciliationLedgerEntry.record(entry, in: db)
      }
      for constraint in constraintPlan.upserts {
        try CalendarTripConstraint.upsert(constraint, in: db)
      }
      for id in constraintPlan.deletions {
        try CalendarTripConstraint.remove(id: id, in: db)
      }
      for stopID in deletedLinkedStopIDs {
        try TripIdea.revertCalendarSchedule(stopID: stopID, in: db)
      }
      for id in ignoredEventIDsToReap {
        try CalendarIgnoredEvent.remove(id: id, in: db)
      }
      for repair in repairs {
        try CalendarPlanRepair.record(repair, in: db)
      }
    }
    updateLocalStateIfNeeded(
      constraintPlan.localState, tripID: tripID, historyStore: historyStore)
  }

  private func updateLocalStateIfNeeded(
    _ nextState: CalendarReconciliationLocalState,
    tripID: Trip.ID,
    historyStore: CalendarReconciliationHistoryStore
  ) {
    guard nextState != localState else { return }
    historyStore.setState(tripID, nextState)
    localState = nextState
  }

  private func ignoredEventIDsToReap(
    tripID: Trip.ID,
    deletedEventIDs: Set<String>,
    allIgnoredEvents: [CalendarIgnoredEvent]
  ) -> [CalendarIgnoredEvent.ID] {
    allIgnoredEvents.filter { ignored in
      ignored.tripID == tripID
        && localState.linkedConstraints.contains { binding in
          guard deletedEventIDs.contains(binding.eventID) else { return false }
          return CalendarReconciliationFingerprint.constraintSource(
            sourceExternalIdentifier: binding.sourceExternalIdentifier,
            occurrenceAnchor: binding.occurrenceAnchor) == ignored.sourceIdentityHash
        }
    }.map(\.id)
  }

  func reconcileCachedUsing(
    trip: Trip,
    plan: TripPlan,
    selectedCalendarID: String,
    cache: IngestionCache?,
    manualLink: (candidateID: String, stop: ResolvedStop)? = nil,
    historyStore: CalendarReconciliationHistoryStore,
    now: Date,
    uuid: @escaping () -> UUID,
    allIgnoredEvents: [CalendarIgnoredEvent],
    allCalendarConstraints: [CalendarTripConstraint]
  ) async {
    guard cache?.tripID == trip.id,
      cache?.calendarID == selectedCalendarID
    else {
      await refresh(trip: trip, plan: plan)
      return
    }
    do {
      let contextFingerprint = try await calendarContextFingerprint(for: trip, plan: plan)
      guard let currentCache = cache,
        currentCache.tripID == trip.id,
        currentCache.calendarID == selectedCalendarID
      else {
        await refresh(trip: trip, plan: plan)
        return
      }
      guard currentCache.contextFingerprint == contextFingerprint else {
        await refresh(trip: trip, plan: plan)
        return
      }
      try await reconcileUsing(
        trip: trip,
        plan: plan,
        cache: currentCache,
        useEventKitEvidence: false,
        manualLink: manualLink,
        historyStore: historyStore,
        now: now,
        uuid: uuid,
        allIgnoredEvents: allIgnoredEvents,
        allCalendarConstraints: allCalendarConstraints)
      state = .loaded
    } catch is CancellationError {
      // Sheet dismissal is normal view-lifecycle cancellation.
    } catch {
      state = .failure(error.localizedDescription)
    }
  }
}
