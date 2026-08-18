import Dependencies
import Foundation
import GalavantPlaces
import GalavantSchema
import SQLiteData
import SwiftUI

/// Retained machinery for a future, deliberate "Add to Shared Calendar" action.
/// M7 reverses the former one-way mirror: Calendar is now ingested as commitment
/// reality, and this writer has no visible entry point.
/// Retained, intentionally unwired — see ADR-0034 §11.
@MainActor
@Observable
final class CalendarExportModel {
  @ObservationIgnored @Dependency(\.calendarExportClient) private var calendarClient
  @ObservationIgnored @Dependency(\.calendarExportIdentityStore) private var identityStore

  enum ExportState: Equatable {
    case idle
    case exporting
    case success(created: Int, updated: Int, deleted: Int)
    case failure(String)
  }

  var state: ExportState = .idle

  var isShowingResult: Bool {
    switch state {
    case .idle, .exporting: false
    case .success, .failure: true
    }
  }

  var resultMessage: String {
    switch state {
    case .idle, .exporting:
      return ""
    case let .success(created, updated, deleted):
      var parts: [String] = []
      if created > 0 { parts.append("\(created) added") }
      if updated > 0 { parts.append("\(updated) updated") }
      if deleted > 0 { parts.append("\(deleted) removed") }
      return parts.isEmpty ? "Calendar is already up to date." : parts.joined(separator: ", ") + "."
    case let .failure(message):
      return message
    }
  }

  func dismissResult() {
    state = .idle
  }

  /// Export/reconcile `trip`'s itinerary to its dedicated device-local calendar.
  /// Guards on `trip.startDate` too (not just a caller's dated-trip visibility
  /// gate), so a stale action after editing the trip cannot export an undated trip.
  func exportButtonTapped(trip: Trip, plan: TripPlan) async {
    guard trip.startDate != nil else {
      state = .failure("This trip has no start date yet — set one before syncing to Calendar.")
      return
    }
    state = .exporting
    do {
      let granted = try await calendarClient.requestAccess()
      guard granted else {
        state = .failure(
          "Calendar access was denied. Enable it for Galavant in Settings > Privacy & Security > Calendars.")
        return
      }
      let items = plan.calendarExportItems(trip: trip)
      let calendarID = try calendarClient.findOrCreateCalendar(calendarTitle(for: trip))
      let existingMapping = identityStore.mapping(trip.id)
      let reconcilePlan = CalendarExportReconciliation.plan(items: items, existingMapping: existingMapping)

      var newMapping: [TripIdea.ID: String] = [:]
      var created = 0
      var updated = 0
      var deleted = 0

      for item in reconcilePlan.toCreate {
        let identifier = try calendarClient.createEvent(item, calendarID)
        newMapping[item.id] = identifier
        created += 1
      }
      for update in reconcilePlan.toUpdate {
        if calendarClient.eventExists(update.identifier) {
          try calendarClient.updateEvent(update.identifier, update.item)
          newMapping[update.item.id] = update.identifier
          updated += 1
        } else {
          // Deleted out from under us (Calendar.app, or a stale identifier) —
          // recreate rather than silently dropping the stop from Calendar.
          let identifier = try calendarClient.createEvent(update.item, calendarID)
          newMapping[update.item.id] = identifier
          created += 1
        }
      }
      for identifier in reconcilePlan.toDeleteIdentifiers {
        try? calendarClient.deleteEvent(identifier)
        deleted += 1
      }

      identityStore.setMapping(trip.id, newMapping)
      state = .success(created: created, updated: updated, deleted: deleted)
    } catch {
      state = .failure(error.localizedDescription)
    }
  }

  /// Stable across exports so `findOrCreateCalendar` finds the same calendar.
  /// Renaming a trip after its first export creates a new calendar rather than
  /// renaming the existing one — an intentionally retained V1 tradeoff.
  private func calendarTitle(for trip: Trip) -> String {
    "Galavant: \(trip.name)"
  }
}

// MARK: - M7 Calendar reconciliation

/// Coordinates a fresh trip-scoped Calendar read, an app-side `PlaceMatcher`
/// pass, the pure reconciliation ladder, and the local auto-apply plan. Only
/// uniquely identified MapKit matches write an existing stop's Calendar-backed
/// time; unmatched events become shared trip constraints. EventKit bindings remain
/// device-local, while domain outcomes ride the trip's CloudKit graph.
@MainActor
@Observable
final class CalendarReconciliationModel {
  private struct PromotionPayload: Sendable {
    let id: Idea.ID
    let name: String
    let description: String
    let notes: String
    let kind: IdeaKind?
    let regionName: String?
    let address: String?
    let phone: String?
    let latitude: Double?
    let longitude: Double?
    let url: String
    let visited: Bool
    let openingHours: String?
    let hoursProvenance: FactProvenance?
    let hoursVerifiedAt: Date?
    let structuredHours: String?
    let enrichedAt: Date?
    let mapItemIdentifier: String?
    let travelPartyID: TravelParty.ID?

    init(draft: Idea.Draft) {
      id = draft.id ?? UUID()
      name = draft.name
      description = draft.description
      notes = draft.notes
      kind = draft.kind
      regionName = draft.regionName
      address = draft.address
      phone = draft.phone
      latitude = draft.latitude
      longitude = draft.longitude
      url = draft.url
      visited = draft.visited
      openingHours = draft.openingHours
      hoursProvenance = draft.hoursProvenance
      hoursVerifiedAt = draft.hoursVerifiedAt
      structuredHours = draft.structuredHours
      enrichedAt = draft.enrichedAt
      mapItemIdentifier = draft.mapItemIdentifier
      travelPartyID = draft.travelPartyID
    }

    var draft: Idea.Draft {
      Idea.Draft(
        Idea(
          id: id,
          name: name,
          description: description,
          notes: notes,
          kind: kind,
          regionName: regionName,
          address: address,
          phone: phone,
          latitude: latitude,
          longitude: longitude,
          url: url,
          visited: visited,
          openingHours: openingHours,
          hoursProvenance: hoursProvenance,
          hoursVerifiedAt: hoursVerifiedAt,
          structuredHours: structuredHours,
          enrichedAt: enrichedAt,
          mapItemIdentifier: mapItemIdentifier,
          travelPartyID: travelPartyID))
    }
  }

  private enum PromotionError: LocalizedError {
    case missingPlaceIdentity
    case missingCalendar
    case missingCandidate
    case missingStop

    var errorDescription: String? {
      switch self {
      case .missingPlaceIdentity:
        "Choose a named Apple Maps place before promoting this event."
      case .missingCalendar:
        "Choose the shared Calendar before promoting this event."
      case .missingCandidate:
        "Galavant could not find the Calendar event behind this constraint. Refresh and try again."
      case .missingStop:
        "Galavant could not place the selected place on this trip."
      }
    }
  }

  enum State: Equatable {
    case idle
    case loading
    case accessDenied
    case calendarSelectionRequired
    case loaded
    case frozen
    case failure(String)
  }

  @ObservationIgnored @Dependency(\.calendarIngestionClient) var calendarClient
  @ObservationIgnored @Dependency(\.calendarSelectionStore) private var calendarSelectionStore
  @ObservationIgnored @Dependency(\.placeMatcher) var placeMatcher
  @ObservationIgnored @Dependency(\.calendarReconciliationHistoryStore) private var historyStore
  @ObservationIgnored @Dependency(\.defaultDatabase) var database
  @ObservationIgnored @Dependency(\.date.now) private var now
  @ObservationIgnored @Dependency(\.uuid) private var uuid
  @ObservationIgnored @FetchAll(CalendarReconciliationLedgerEntry.all) private var allLedgerEntries
  @ObservationIgnored @FetchAll(CalendarTripConstraint.all) private var allCalendarConstraints
  @ObservationIgnored @FetchAll(CalendarIgnoredEvent.all) private var allIgnoredEvents
  @ObservationIgnored @FetchAll(CalendarPlanRepair.all) private var allPlanRepairs
  @ObservationIgnored @FetchAll(CalendarPlanRepairResolution.all) private var allPlanRepairResolutions

  private struct IngestionCache {
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

  var state: State = .idle
  var candidates: [CalendarReconciliationCandidate] = []
  var candidateForLink: CalendarReconciliationCandidate?
  private var ingestionCache: IngestionCache?
  private var currentTripID: Trip.ID?
  var isShowingIgnored = false
  var localState = CalendarReconciliationLocalState()
  var calendars: [CalendarSource] = []
  var selectedCalendarID: String? { calendarSelectionStore.calendarID() }

  var sharedHistory: [CalendarReconciliationLedgerEntry] { allLedgerEntries }
  var ignoredEvents: [CalendarIgnoredEvent] {
    guard let currentTripID else { return [] }
    return allIgnoredEvents.filter { $0.tripID == currentTripID }
  }
  var planRepairs: [CalendarPlanRepair] {
    let resolutions = allPlanRepairResolutions.reduce(into: [CalendarPlanRepair.ID: CalendarPlanRepairResolution]()) {
      partial, resolution in
      guard let current = partial[resolution.repairID] else {
        partial[resolution.repairID] = resolution
        return
      }
      if resolution.resolvedAt < current.resolvedAt {
        partial[resolution.repairID] = resolution
      }
    }
    return allPlanRepairs.map { $0.resolved(by: resolutions[$0.id]) }
  }

  func refresh(trip: Trip, plan: TripPlan) async {
    guard state != .loading else { return }
    currentTripID = trip.id
    guard trip.calendarReconciliationFrozenAt == nil else {
      state = .frozen
      return
    }
    let regionTimeZone = await regionTimeZone(for: trip, plan: plan)
    var tripCalendar = Calendar(identifier: .gregorian)
    tripCalendar.timeZone = regionTimeZone ?? Self.storageTimeZone
    guard let scope = scope(for: trip, calendar: tripCalendar),
      let queryInterval = scope.queryInterval(in: Self.storageTimeZone)
    else {
      state = .failure("Calendar reconciliation needs a dated trip.")
      return
    }
    state = .loading
    do {
      let granted = try await calendarClient.requestFullAccess()
      guard granted, calendarClient.hasFullAccess() else {
        state = .accessDenied
        return
      }

      calendars = calendarClient.calendars()
      guard let selectedCalendarID, calendars.contains(where: { $0.id == selectedCalendarID }) else {
        state = .calendarSelectionRequired
        return
      }

      let cache = try await fetchAndIngest(
        trip: trip,
        plan: plan,
        scope: scope,
        queryInterval: queryInterval,
        selectedCalendarID: selectedCalendarID,
        regionTimeZone: regionTimeZone,
        tripCalendar: tripCalendar)
      ingestionCache = cache
      try await reconcile(trip: trip, plan: plan, cache: cache, useEventKitEvidence: true)
      state = .loaded
    } catch is CancellationError {
      // Sheet dismissal is normal view-lifecycle cancellation.
    } catch {
      state = .failure(error.localizedDescription)
    }
  }

  func selectCalendar(_ id: String?) {
    calendarSelectionStore.setCalendarID(id)
  }

  private func fetchAndIngest(
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

  private func reconcile(
    trip: Trip,
    plan: TripPlan,
    cache: IngestionCache,
    useEventKitEvidence: Bool,
    manualLink: (candidateID: String, stop: ResolvedStop)? = nil
  ) async throws {
    localState = historyStore.state(trip.id)
    let ignoredSourceIdentityHashes = Set(
      allIgnoredEvents.filter { $0.tripID == trip.id }.map(\.sourceIdentityHash))
    var reconciledCandidates = CalendarReconciliation.candidates(
      for: cache.ingestedEvents,
      trip: trip,
      plan: plan,
      temporalContext: cache.temporalContext,
      ignoredSourceIdentityHashes: ignoredSourceIdentityHashes)
    if let manualLink,
      let index = reconciledCandidates.firstIndex(where: { $0.id == manualLink.candidateID })
    {
      reconciledCandidates[index] = CalendarReconciliation.manuallyLinkedCandidate(
        reconciledCandidates[index], to: manualLink.stop)
    }
    candidates = reconciledCandidates

    let outsideTripObservations: [CalendarBoundEventObservation] = useEventKitEvidence
      ? localState.linkedStops.compactMap { linked in
        guard
          let event = calendarClient.event(linked.eventID),
          cache.temporalContext.project(
            event.temporal,
            absoluteTimeZone: linked.itineraryTimeZone) == .outsideTrip
        else { return nil }
        return CalendarBoundEventObservation(bindingID: linked.eventID, event: event)
      }
      : []
    let automaticPlan = CalendarReconciliation.automaticPlan(
      candidates: candidates,
      outsideTripObservations: outsideTripObservations,
      localState: localState,
      observedAt: now,
      makeHistoryID: { uuid() },
      manuallyRelinkedSourceFingerprint: manualLink.flatMap { manual in
        reconciledCandidates
          .first(where: { $0.id == manual.candidateID })
          .flatMap { CalendarReconciliationFingerprint.source(for: $0.input.event) }
      })
    let previousDayNumbers = Dictionary(
      uniqueKeysWithValues: plan.entries.compactMap { entry in
        entry.dayNumber.map { (entry.id, $0) }
      })
    let deletedEventIDs = useEventKitEvidence
      ? deletedConstraintEventIDs(
        observedEvents: cache.observedEvents, selectedCalendarID: cache.calendarID)
      : []
    let ignoredEventIDsToReap = useEventKitEvidence
      ? ignoredEventIDsToReap(tripID: trip.id, deletedEventIDs: deletedEventIDs)
      : []
    let constraintPlan = CalendarReconciliation.constraintPlan(
      candidates: candidates,
      tripID: trip.id,
      calendarID: cache.calendarID,
      localState: automaticPlan.localState,
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
    let repairs = CalendarReconciliation.planRepairs(
      applications: automaticPlan.applications,
      previousDayNumbers: previousDayNumbers,
      history: constraintPlan.localState.history, tripID: trip.id)
    try await persist(
      automaticPlan, constraintPlan: constraintPlan, repairs: repairs,
      tripID: trip.id, ignoredEventIDsToReap: ignoredEventIDsToReap)
    if useEventKitEvidence, trip.isPast(at: now, calendar: cache.tripCalendar) {
      let frozenAt = now
      try await database.write { db in
        try Trip.completeCalendarReconciliation(tripID: trip.id, frozenAt: frozenAt, in: db)
      }
    }
  }

  private func persist(
    _ plan: CalendarReconciliationAutomaticPlan,
    constraintPlan: CalendarConstraintAutomaticPlan,
    repairs: [CalendarPlanRepair],
    tripID: Trip.ID,
    ignoredEventIDsToReap: [CalendarIgnoredEvent.ID] = []
  ) async throws {
    let newHistory = constraintPlan.localState.history.dropFirst(localState.history.count)
    let ledgerEntries = newHistory.compactMap {
      CalendarReconciliationLedgerEntry(tripID: tripID, historyEntry: $0)
    }
    if !plan.applications.isEmpty
      || !ledgerEntries.isEmpty
      || !constraintPlan.upserts.isEmpty
      || !constraintPlan.deletions.isEmpty
      || !ignoredEventIDsToReap.isEmpty
      || !repairs.isEmpty
    {
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
        for id in ignoredEventIDsToReap {
          try CalendarIgnoredEvent.remove(id: id, in: db)
        }
        for repair in repairs {
          try CalendarPlanRepair.record(repair, in: db)
        }
      }
    }
    if constraintPlan.localState != localState {
      historyStore.setState(tripID, constraintPlan.localState)
      localState = constraintPlan.localState
    }
  }

  private func ignoredEventIDsToReap(
    tripID: Trip.ID, deletedEventIDs: Set<String>
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

  func resolvePlanRepair(_ repair: CalendarPlanRepair) {
    guard !repair.isResolved else { return }
    let resolvedAt = now
    withErrorReporting {
      try database.write { db in
        try CalendarPlanRepair.resolve(id: repair.id, at: resolvedAt, in: db)
      }
    }
  }

  func isLinked(_ candidate: CalendarReconciliationCandidate) -> Bool {
    CalendarReconciliation.linkedStopIndex(
      for: candidate.input.event, in: localState.linkedStops) != nil
  }

  private func reconcileCached(
    trip: Trip,
    plan: TripPlan,
    selectedCalendarID: String,
    manualLink: (candidateID: String, stop: ResolvedStop)? = nil
  ) async {
    guard ingestionCache?.tripID == trip.id,
      ingestionCache?.calendarID == selectedCalendarID
    else {
      await refresh(trip: trip, plan: plan)
      return
    }
    do {
      let contextFingerprint = try await calendarContextFingerprint(for: trip, plan: plan)
      guard let currentCache = ingestionCache,
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
      try await reconcile(
        trip: trip,
        plan: plan,
        cache: currentCache,
        useEventKitEvidence: false,
        manualLink: manualLink)
      state = .loaded
    } catch is CancellationError {
      // Sheet dismissal is normal view-lifecycle cancellation.
    } catch {
      state = .failure(error.localizedDescription)
    }
  }

  func link(
    _ candidate: CalendarReconciliationCandidate,
    to stop: ResolvedStop,
    trip: Trip,
    plan: TripPlan,
    selectedCalendarID: String
  ) async {
    guard candidate.input.event.isEligibleForSharedReconciliation else { return }
    await reconcileCached(
      trip: trip,
      plan: plan,
      selectedCalendarID: selectedCalendarID,
      manualLink: (candidateID: candidate.id, stop: stop))
  }

  /// Assigns a real Maps place to a Calendar constraint, then sends the resulting
  /// idea-backed day stop through the established manual-link path. Calendar owns
  /// the event's time; `link` is the only operation that applies it.
  func promote(
    constraint: CalendarTripConstraint,
    place: Place,
    trip: Trip,
    plan: TripPlan
  ) async {
    do {
      guard place.mapItemIdentifier != nil else { throw PromotionError.missingPlaceIdentity }
      guard constraint.tripID == trip.id else { throw PromotionError.missingCandidate }
      guard let selectedCalendarID else { throw PromotionError.missingCalendar }

      if CalendarReconciliation.candidate(for: constraint, in: candidates) == nil {
        await refresh(trip: trip, plan: plan)
      }
      guard let candidate = CalendarReconciliation.candidate(for: constraint, in: candidates),
        candidate.input.event.isEligibleForSharedReconciliation,
        candidate.input.event.hasStableLocalIdentity
      else { throw PromotionError.missingCandidate }

      let draft = PromotionPayload(draft: await MapPlaceCapture().draft(for: place))
      let stopID = try await database.write { db in
        let ideaID = try Idea.save(draft.draft, tagNames: [], in: db)
        let stop = try TripIdea.pull(ideaID: ideaID, into: trip.id, in: db)
        try TripIdea.schedule(.day(constraint.dayNumber), stopID: stop.id, in: db)
        return stop.id
      }
      let updatedPlan = try await planAfterPromoting(
        stopID: stopID, tripID: trip.id, base: plan)
      guard let stop = updatedPlan.itinerary.flatMap(\.stops).first(where: { $0.id == stopID })
      else {
        throw PromotionError.missingStop
      }

      await link(
        candidate,
        to: stop,
        trip: trip,
        plan: updatedPlan,
        selectedCalendarID: selectedCalendarID)
    } catch {
      state = .failure(error.localizedDescription)
    }
  }

  private func planAfterPromoting(
    stopID: TripIdea.ID,
    tripID: Trip.ID,
    base: TripPlan
  ) async throws -> TripPlan {
    try await database.read { db in
      var plan = base
      plan.entries = try TripIdea.where { $0.tripID.eq(tripID) }.fetchAll(db)
      guard let stop = plan.entries.first(where: { $0.id == stopID }),
        let ideaID = stop.ideaID,
        let idea = try Idea.find(ideaID).fetchOne(db)
      else { throw PromotionError.missingStop }
      plan.ideasByID[idea.id] = idea
      return plan
    }
  }

  func unlink(_ candidate: CalendarReconciliationCandidate, trip: Trip, plan: TripPlan) async {
    guard let unlinkPlan = CalendarReconciliation.unlinkPlan(
      candidate: candidate, localState: localState,
      observedAt: now, makeHistoryID: { uuid() })
    else { return }
    do {
      try await database.write { db in
        try TripIdea.revertCalendarSchedule(stopID: unlinkPlan.stopID, in: db)
      }
      historyStore.setState(trip.id, unlinkPlan.localState)
      localState = unlinkPlan.localState
      if let selectedCalendarID {
        await reconcileCached(
          trip: trip, plan: plan, selectedCalendarID: selectedCalendarID)
      }
    } catch {
      state = .failure(error.localizedDescription)
    }
  }

  func ignore(_ candidate: CalendarReconciliationCandidate, trip: Trip, plan: TripPlan) async {
    guard let ignored = CalendarIgnoredEvent(
      tripID: trip.id, event: candidate.input.event, ignoredAt: now)
    else { return }
    do {
      try await database.write { db in
        try CalendarIgnoredEvent.upsert(ignored, in: db)
      }
      if let selectedCalendarID {
        await reconcileCached(
          trip: trip, plan: plan, selectedCalendarID: selectedCalendarID)
      } else {
        await refresh(trip: trip, plan: plan)
      }
    } catch {
      state = .failure(error.localizedDescription)
    }
  }

  func unignore(_ ignored: CalendarIgnoredEvent, trip: Trip, plan: TripPlan) async {
    do {
      try await database.write { db in
        try CalendarIgnoredEvent.remove(id: ignored.id, in: db)
      }
      if let selectedCalendarID {
        await reconcileCached(
          trip: trip, plan: plan, selectedCalendarID: selectedCalendarID)
      } else {
        await refresh(trip: trip, plan: plan)
      }
    } catch {
      state = .failure(error.localizedDescription)
    }
  }

  /// A missing device-local EventKit identifier is necessary but insufficient
  /// deletion evidence because sync may replace that identifier. A healthy
  /// full-access read therefore corroborates absence through the event's server
  /// identity before a Calendar-originated constraint is removed. A missing
  /// recurring occurrence stays unknown while its series remains visible.
}

struct CalendarReconciliationSheet: View {
  let model: CalendarReconciliationModel
  let trip: Trip
  let plan: TripPlan
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("Calendar is authoritative for linked commitments and unmatched trip constraints. Applied updates are shared with your travel party.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        if !model.calendars.isEmpty {
          Section("Calendar to Read") {
            Picker("Calendar", selection: Binding(
              get: { model.selectedCalendarID },
              set: { id in
                model.selectCalendar(id)
                if id != nil { Task { await model.refresh(trip: trip, plan: plan) } }
              }
            )) {
              Text("Choose a Calendar").tag(String?.none)
              ForEach(model.calendars) { calendar in
                Text(calendar.title).tag(String?.some(calendar.id))
              }
            }
            .disabled(model.state == .loading)
          }
        }

        switch model.state {
        case .idle, .loading:
          Section { ProgressView("Reading shared calendars…") }
        case .accessDenied:
          Section("Calendar Access") {
            Text("Full Calendar access is unavailable. Galavant made no deletion or itinerary decision.")
          }
        case .calendarSelectionRequired:
          Section("Choose a Calendar") {
            Text("Select the one shared calendar Galavant may read. It will not inspect your other calendars.")
          }
        case let .failure(message):
          Section("Calendar Read Failed") { Text(message) }
        case .loaded, .frozen:
          candidateSections
        }
      }
      .navigationTitle("Calendar Reconciliation")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Refresh") {
            Task { await model.refresh(trip: trip, plan: plan) }
          }
          .disabled(model.state == .loading)
        }
      }
      .task(id: trip.id) { await model.refresh(trip: trip, plan: plan) }
      .onChange(of: scenePhase) { _, phase in
        guard phase == .active else { return }
        Task { await model.refresh(trip: trip, plan: plan) }
      }
      .sheet(item: Binding(
        get: { model.candidateForLink },
        set: { model.candidateForLink = $0 }
      )) { candidate in
        NavigationStack {
          List(ambiguousStops(in: candidate)) { stop in
            Button {
              model.candidateForLink = nil
              Task {
                guard let selectedCalendarID = model.selectedCalendarID else { return }
                await model.link(
                  candidate, to: stop, trip: trip, plan: plan, selectedCalendarID: selectedCalendarID)
              }
            } label: {
              Text(stop.content.title)
            }
          }
          .navigationTitle("Link to Stop")
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Cancel") { model.candidateForLink = nil }
            }
          }
        }
      }
    }
  }

  @ViewBuilder private var candidateSections: some View {
    let automatic = model.candidates.filter {
      if case .automatic = $0.result { true } else { false }
    }
    let proposed = model.candidates.filter {
      if case .proposed = $0.result { true } else { false }
    }
    let ambiguous = model.candidates.filter {
      if case .ambiguous = $0.result { true } else { false }
    }
    let needsTimeZone = model.candidates.filter {
      if case .unresolvedTimeZone = $0.result { true } else { false }
    }
    let unmatched = model.candidates.filter {
      if case .unmatched = $0.result { true } else { false }
    }

    if model.state == .frozen {
      Section("Calendar Reconciliation Frozen") {
        Text("This trip is complete. Its final Calendar state is preserved as history and later Calendar cleanup will not change it.")
      }
    } else if model.candidates.isEmpty {
      ContentUnavailableView("No events in this trip's dates", systemImage: "calendar")
    } else {
      if !automatic.isEmpty {
        Section("High-Confidence Matches") {
          ForEach(automatic, content: candidateRow)
        }
      }
      if !proposed.isEmpty {
        Section("Potential Matches") {
          ForEach(proposed, content: candidateRow)
        }
      }
      if !ambiguous.isEmpty {
        Section("Needs Later Review") {
          ForEach(ambiguous, content: candidateRow)
        }
      }
      if !needsTimeZone.isEmpty {
        Section("Time Zone Needs Review") {
          ForEach(needsTimeZone, content: candidateRow)
        }
      }
      if !unmatched.isEmpty {
        Section("No Itinerary Match") {
          ForEach(unmatched, content: candidateRow)
        }
      }
    }
    if !model.ignoredEvents.isEmpty {
      DisclosureGroup(
        "Ignored",
        isExpanded: Binding(
          get: { model.isShowingIgnored },
          set: { model.isShowingIgnored = $0 }))
      {
        ForEach(model.ignoredEvents) { ignored in
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text(ignored.title)
              Text("Dismissed for this trip.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Un-ignore") {
              Task { await model.unignore(ignored, trip: trip, plan: plan) }
            }
            .font(.caption.weight(.semibold))
          }
        }
      }
    }
    // A linked stop whose event drifted out of the trip window is surfaced as a
    // party-wide, actionable "Plan Repair" (below), not a separate device-local
    // notice — the shared repair supersedes the old informational section.
    let history = model.sharedHistory.filter { $0.tripID == trip.id }
    if !history.isEmpty {
      Section("Calendar History") {
        ForEach(history.reversed()) { entry in
          historyRow(entry)
        }
      }
    }
    let repairs = model.planRepairs.filter { $0.tripID == trip.id }
    if !repairs.isEmpty {
      Section("Plan Repair") {
        ForEach(repairs) { repair in
          planRepairRow(repair)
        }
      }
    }
  }

  private func ambiguousStops(in candidate: CalendarReconciliationCandidate) -> [ResolvedStop] {
    if case let .ambiguous(stops) = candidate.result { return stops }
    return []
  }

}
