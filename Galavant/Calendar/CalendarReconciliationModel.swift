import Dependencies
import Foundation
import GalavantSchema
import SQLiteData
import SwiftUI

// MARK: - M7 Calendar reconciliation

/// Coordinates a fresh trip-scoped Calendar read, an app-side `PlaceMatcher`
/// pass, the pure reconciliation ladder, and the local auto-apply plan. Only
/// uniquely identified MapKit matches write an existing stop's Calendar-backed
/// time; unmatched events become shared trip constraints. EventKit bindings remain
/// device-local, while domain outcomes ride the trip's CloudKit graph.
@MainActor
@Observable
final class CalendarReconciliationModel {
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
    try await makeIngestionCache(
      trip: trip,
      plan: plan,
      scope: scope,
      queryInterval: queryInterval,
      selectedCalendarID: selectedCalendarID,
      regionTimeZone: regionTimeZone,
      tripCalendar: tripCalendar)
  }

  private func reconcile(
    trip: Trip,
    plan: TripPlan,
    cache: IngestionCache,
    useEventKitEvidence: Bool,
    manualLink: (candidateID: String, stop: ResolvedStop)? = nil
  ) async throws {
    try await reconcileUsing(
      trip: trip,
      plan: plan,
      cache: cache,
      useEventKitEvidence: useEventKitEvidence,
      manualLink: manualLink,
      historyStore: historyStore,
      now: now,
      uuid: { self.uuid() },
      allIgnoredEvents: allIgnoredEvents,
      allCalendarConstraints: allCalendarConstraints)
  }

  private func reconcileCached(
    trip: Trip,
    plan: TripPlan,
    selectedCalendarID: String,
    manualLink: (candidateID: String, stop: ResolvedStop)? = nil
  ) async {
    await reconcileCachedUsing(
      trip: trip,
      plan: plan,
      selectedCalendarID: selectedCalendarID,
      cache: ingestionCache,
      manualLink: manualLink,
      historyStore: historyStore,
      now: now,
      uuid: { self.uuid() },
      allIgnoredEvents: allIgnoredEvents,
      allCalendarConstraints: allCalendarConstraints)
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
}
