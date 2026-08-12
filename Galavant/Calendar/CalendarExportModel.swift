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
/// time. EventKit bindings remain device-local, while the resulting review ledger
/// is shared through the trip's CloudKit graph (Slice 3).
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
    let tripCalendar = Calendar.current
    guard let scope = scope(for: trip, calendar: tripCalendar),
      let queryInterval = scope.queryInterval(in: Self.storageTimeZone)
    else {
      state = .failure("Calendar reconciliation needs a dated trip.")
      return
    }
    let temporalContext = CalendarTripTemporalContext(scope: scope)

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

      localState = historyStore.state(trip.id)
      // Query two padded days on either side, then let the pure civil/absolute
      // scope discard the padding. Two days covers even the widest real-world
      // zone separation at a trip-day boundary.
      let events = try calendarClient.events(queryInterval, [selectedCalendarID]).filter {
        scope.overlaps($0.temporal, absoluteTimeZone: nil) != false
      }
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
      try await persist(automaticPlan, tripID: trip.id)
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

  private func persist(
    _ plan: CalendarReconciliationAutomaticPlan,
    tripID: Trip.ID
  ) async throws {
    let newHistory = plan.localState.history.dropFirst(localState.history.count)
    let ledgerEntries = newHistory.compactMap {
      CalendarReconciliationLedgerEntry(tripID: tripID, historyEntry: $0)
    }
    if !plan.applications.isEmpty || !ledgerEntries.isEmpty {
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
      }
    }
    if plan.localState != localState {
      historyStore.setState(tripID, plan.localState)
      localState = plan.localState
    }
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
          Text("Calendar is authoritative for high-confidence linked commitments. Applied updates are shared with your travel party.")
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
    let history = model.sharedHistory.filter { $0.tripID == trip.id }
    if !history.isEmpty {
      Section("Calendar History") {
        ForEach(history.reversed()) { entry in
          historyRow(entry)
        }
      }
    }
  }

  private func historyRow(_ entry: CalendarReconciliationLedgerEntry) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(entry.eventTitle)
      Text("Calendar commitment recorded.")
        .font(.caption)
        .foregroundStyle(.secondary)
      if let current = entry.current {
        Text(temporalDescription(current.temporal))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func candidateRow(_ candidate: CalendarReconciliationCandidate) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(candidate.input.event.title)
      Text(candidate.input.event.calendarTitle)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(temporalDescription(candidate.input.event.temporal))
        .font(.caption)
        .foregroundStyle(.secondary)
      switch candidate.result {
      case let .automatic(stop, basis):
        Text("Matches \(stop.content.title) by \(basisDescription(basis)).")
          .font(.caption)
          .foregroundStyle(.green)
      case let .proposed(stop, basis):
        Text("Possible match: \(stop.content.title) by \(basisDescription(basis)).")
          .font(.caption)
      case let .ambiguous(stops):
        Text("Could be: \(stops.map(\.content.title).joined(separator: ", ")).")
          .font(.caption)
      case .unresolvedTimeZone:
        Text("Travel time zone needs review before this event can be placed on a trip day.")
          .font(.caption)
      case .unmatched:
        Text("No same-day itinerary stop matches this event.")
          .font(.caption)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func basisDescription(_ basis: CalendarMatchBasis) -> String {
    switch basis {
    case .mapItemIdentifier: "the same Apple Maps place"
    case .exactName: "the exact place name"
    case .nameAndProximity: "a nearby place with a shared name"
    }
  }

  private func temporalDescription(_ temporal: CalendarEventTime) -> String {
    switch temporal {
    case let .absolute(start, _, timeZone):
      var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
      style.timeZone = timeZone
      return start.formatted(style)
    case let .floating(start, _):
      return String(
        format: "%d/%d/%04d %02d:%02d (floating)",
        start.date.month, start.date.day, start.date.year, start.hour, start.minute)
    case let .allDay(start, endExclusive):
      if endExclusive == start.adding(days: 1) {
        return String(format: "%d/%d/%04d (all day)", start.month, start.day, start.year)
      }
      let inclusiveEnd = endExclusive.adding(days: -1) ?? endExclusive
      return String(
        format: "%d/%d/%04d–%d/%d/%04d (all day)",
        start.month, start.day, start.year,
        inclusiveEnd.month, inclusiveEnd.day, inclusiveEnd.year)
    }
  }
}
