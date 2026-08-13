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
  enum State: Equatable {
    case idle
    case loading
    case accessDenied
    case calendarSelectionRequired
    case loaded
    case failure(String)
  }

  @ObservationIgnored @Dependency(\.calendarIngestionClient) private var calendarClient
  @ObservationIgnored @Dependency(\.calendarSelectionStore) private var calendarSelectionStore
  @ObservationIgnored @Dependency(\.placeMatcher) private var placeMatcher
  @ObservationIgnored @Dependency(\.calendarReconciliationHistoryStore) private var historyStore
  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @Dependency(\.date.now) private var now
  @ObservationIgnored @Dependency(\.uuid) private var uuid
  @ObservationIgnored @FetchAll(CalendarReconciliationLedgerEntry.all) private var allLedgerEntries

  var state: State = .idle
  var candidates: [CalendarReconciliationCandidate] = []
  var localState = CalendarReconciliationLocalState()
  var calendars: [CalendarSource] = []
  var selectedCalendarID: String? { calendarSelectionStore.calendarID() }

  var sharedHistory: [CalendarReconciliationLedgerEntry] { allLedgerEntries }

  func refresh(trip: Trip, plan: TripPlan) async {
    guard state != .loading else { return }
    let tripCalendar = Calendar.current
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

      try await reconcile(
        trip: trip,
        plan: plan,
        scope: scope,
        queryInterval: queryInterval,
        selectedCalendarID: selectedCalendarID)
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

  private func reconcile(
    trip: Trip,
    plan: TripPlan,
    scope: CalendarTripScope,
    queryInterval: DateInterval,
    selectedCalendarID: String
  ) async throws {
    localState = historyStore.state(trip.id)
    // Query two padded days on either side, then let the pure civil/absolute
    // scope discard the padding. Two days covers even the widest real-world
    // zone separation at a trip-day boundary.
    let events = try calendarClient.events(queryInterval, [selectedCalendarID]).filter {
      scope.overlaps($0.temporal, absoluteTimeZone: nil) != false
    }
    let temporalContext = CalendarTripTemporalContext(scope: scope)
    let regionTimeZone = await regionTimeZone(for: trip)
    let ingestedEvents = try await ingest(events, regionTimeZone: regionTimeZone)
    candidates = CalendarReconciliation.candidates(
      for: ingestedEvents,
      trip: trip,
      plan: plan,
      temporalContext: temporalContext)
    let outsideTripObservations: [CalendarBoundEventObservation] = localState.linkedStops.compactMap { linked in
      guard
        let event = calendarClient.event(linked.eventID),
        temporalContext.project(
          event.temporal,
          absoluteTimeZone: linked.itineraryTimeZone) == .outsideTrip
      else { return nil }
      return CalendarBoundEventObservation(bindingID: linked.eventID, event: event)
    }
    let automaticPlan = CalendarReconciliation.automaticPlan(
      candidates: candidates,
      outsideTripObservations: outsideTripObservations,
      localState: localState,
      observedAt: now,
      makeHistoryID: { uuid() })
    let constraintPlan = CalendarReconciliation.constraintPlan(
      candidates: candidates,
      tripID: trip.id,
      calendarID: selectedCalendarID,
      localState: automaticPlan.localState,
      deletedEventIDs: deletedConstraintEventIDs(
        observedEvents: events,
        selectedCalendarID: selectedCalendarID),
      movedOutsideEventIDs: movedOutsideConstraintEventIDs(
        selectedCalendarID: selectedCalendarID,
        temporalContext: temporalContext,
        regionTimeZone: regionTimeZone),
      regionTimeZone: regionTimeZone)
    try await persist(automaticPlan, constraintPlan: constraintPlan, tripID: trip.id)
  }

  private func persist(
    _ plan: CalendarReconciliationAutomaticPlan,
    constraintPlan: CalendarConstraintAutomaticPlan,
    tripID: Trip.ID
  ) async throws {
    let newHistory = constraintPlan.localState.history.dropFirst(localState.history.count)
    let ledgerEntries = newHistory.compactMap {
      CalendarReconciliationLedgerEntry(tripID: tripID, historyEntry: $0)
    }
    if !plan.applications.isEmpty
      || !ledgerEntries.isEmpty
      || !constraintPlan.upserts.isEmpty
      || !constraintPlan.deletions.isEmpty
    {
      try await database.write { db in
        for application in plan.applications {
          try TripIdea.applyCalendarCommitment(
            application.commitment,
            stopID: application.stopID,
            dayNumber: application.dayNumber,
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
      }
    }
    if constraintPlan.localState != localState {
      historyStore.setState(tripID, constraintPlan.localState)
      localState = constraintPlan.localState
    }
  }

  /// A missing device-local EventKit identifier is necessary but insufficient
  /// deletion evidence because sync may replace that identifier. A healthy
  /// full-access read therefore corroborates absence through the event's server
  /// identity before a Calendar-originated constraint is removed. A missing
  /// recurring occurrence stays unknown while its series remains visible.
  private func deletedConstraintEventIDs(
    observedEvents: [CalendarObservedEvent],
    selectedCalendarID: String
  ) -> Set<String> {
    Set(localState.linkedConstraints.compactMap { binding in
      guard binding.calendarID == selectedCalendarID,
        !observedEvents.contains(where: binding.matches),
        calendarClient.event(binding.eventID) == nil
      else { return nil }

      let serverMatches = calendarClient.eventsWithExternalIdentifier(
        binding.sourceExternalIdentifier)
      guard !serverMatches.contains(where: binding.matches) else { return nil }
      guard !calendarClient.hasCalendarItemsWithExternalIdentifier(
        binding.sourceExternalIdentifier) else { return nil }
      return binding.eventID
    })
  }

  /// A Calendar-originated constraint whose event is confirmed present but now
  /// projects outside the trip window is no longer a current trip constraint: its
  /// shared row is dropped while the device-local binding is retained, so a move
  /// back into the trip recreates the same deterministic constraint. This is
  /// distinct from deletion (§6, the check above) and from mere non-observation
  /// (§10): only a healthy full-access read that resolves the event and projects it
  /// outside the trip triggers it. Unmatched constraints were projected in the
  /// trip's region zone, so that is the frame used here.
  private func movedOutsideConstraintEventIDs(
    selectedCalendarID: String,
    temporalContext: CalendarTripTemporalContext,
    regionTimeZone: TimeZone?
  ) -> Set<String> {
    Set(localState.linkedConstraints.compactMap { binding in
      guard binding.calendarID == selectedCalendarID,
        let event = calendarClient.event(binding.eventID),
        temporalContext.project(
          event.temporal, absoluteTimeZone: regionTimeZone) == .outsideTrip
      else { return nil }
      return binding.eventID
    })
  }

  private func ingest(
    _ events: [CalendarObservedEvent],
    regionTimeZone: TimeZone?
  ) async throws -> [CalendarIngestedEvent] {
    var ingested: [CalendarIngestedEvent] = []
    for event in events {
      try Task.checkCancellation()
      let match = await placeMatcher.match(
        calendarEventTitle: event.title,
        latitude: event.latitude,
        longitude: event.longitude,
        location: event.location
      )
      let matchedPlace = match.map {
        CalendarMatchedPlace(name: $0.name ?? event.title, mapItemIdentifier: $0.mapItemIdentifier)
      }
      // The trip's destination (region) zone is the projection frame for every
      // event's trip day — ADR-0034's actual intent: place an absolute instant on
      // the *destination's* civil day. A matched venue's own zone is only a fallback
      // for a region-less trip; it must not override the destination, or a wrong
      // worldwide name-match could push a just-after-midnight event onto the prior
      // day and silently drop it. Only when neither resolves does the event stay
      // `.unresolvedTimeZone` — still visible in the sheet, never dropped.
      let itineraryTimeZone = regionTimeZone
        ?? match?.timeZoneIdentifier.flatMap(TimeZone.init(identifier:))
      ingested.append(CalendarIngestedEvent(
        event: event,
        matchedPlace: matchedPlace,
        itineraryTimeZone: itineraryTimeZone))
    }
    return ingested
  }

  /// A principled destination zone for the whole trip, derived from its planning
  /// region(s) by reverse-geocoding their bounding-box center. Used only as the
  /// fallback when a matched place resolved no zone; never the device or event
  /// zone (ADR-0034). Nil when the trip has no region or the lookup fails, which
  /// keeps a genuinely unplaceable absolute event visibly unresolved.
  private func regionTimeZone(for trip: Trip) async -> TimeZone? {
    let regions = (try? await database.read { db -> [MapRegion] in
      let ids = try TripRegion.regionIDs(forTrip: trip.id, in: db)
      return try MapRegion.where { $0.id.in(ids) }.fetchAll(db)
    }) ?? []
    guard let box = MapRegion.boundingBox(of: regions) else { return nil }
    return await placeMatcher.timeZone(
      latitude: box.centerLatitude, longitude: box.centerLongitude)
  }

  /// Full first and last civil days. EventKit querying is padded separately so
  /// this remains the pure semantic boundary for zoned, floating, and all-day time.
  private func scope(for trip: Trip, calendar: Calendar) -> CalendarTripScope? {
    guard let startDate = trip.startDate else { return nil }
    return CalendarTripScope(
      start: CalendarCivilDate(startDate, calendar: calendar),
      dayCount: trip.lengthInDays)
  }

  private static let storageTimeZone = TimeZone(secondsFromGMT: 0)!
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
        case .loaded:
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

    if model.candidates.isEmpty {
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
    // Device-local: a linked stop whose event drifted out of the trip window. The
    // itinerary cache is deliberately preserved and the binding retained (so it heals
    // if the event returns), so this is not promoted to the shared ledger. Surfacing
    // it as a party-wide conflict is Slice 6 (plan-repair).
    let movedOutside = model.localState.linkedStops.filter { $0.movedOutsideTripCommitment != nil }
    if !movedOutside.isEmpty {
      Section("Moved Outside This Trip") {
        ForEach(movedOutside, id: \.stopID, content: movedOutsideRow)
      }
    }
    let history = model.sharedHistory.filter { $0.tripID == trip.id }
    if !history.isEmpty {
      Section("Calendar History") {
        ForEach(history.reversed()) { entry in
          historyRow(entry)
        }
      }
    }
  }

}
