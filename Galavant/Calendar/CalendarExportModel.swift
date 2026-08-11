import Dependencies
import Foundation
import GalavantPlaces
import GalavantSchema
import SwiftUI

/// Drives the per-trip "Sync to Calendar" action (BACKLOG "Export itinerary to
/// Apple Calendar / iCal"): compute this trip's calendar-export items (pure,
/// `TripPlan.calendarExportItems`), diff them against the local-only identity
/// mapping (pure, `CalendarExportReconciliation.plan`), then carry that plan
/// out against the injectable EventKit client. Respects the settled one-way,
/// per-device mirror design — Galavant writes, nothing reads back, no shared
/// calendar, and the identifier mapping never rides CloudKit sync.
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

  /// Whether the result alert should be showing — `true` for a completed
  /// success or failure, `false` while idle/in flight.
  var isShowingResult: Bool {
    switch state {
    case .idle, .exporting: false
    case .success, .failure: true
    }
  }

  /// The result alert's message, empty while idle/in flight.
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

  /// Export/reconcile `trip`'s itinerary to its dedicated device-local
  /// calendar. Guards on `trip.startDate` too (not just the caller's visibility
  /// gate on `Certainty.dated`) so a stale button tap on an edited trip can't
  /// misfire against an undated trip.
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
          // recreate rather than silently dropping the stop from the calendar.
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

  /// The dedicated per-trip calendar's name — stable across exports so
  /// `findOrCreateCalendar` finds the same one on re-export. A rename of the
  /// trip after a first export creates a *new* calendar rather than renaming
  /// the old one (v1 tradeoff, noted in the PR).
  private func calendarTitle(for trip: Trip) -> String {
    "Galavant: \(trip.name)"
  }
}

// MARK: - M7 Slice 0 observation spike

/// A candidate match the spike holds only while its sheet is on screen. This is
/// deliberately a review value, not a binding: later slices decide the matching
/// threshold and durable ledger semantics after this proves EventKit behavior.
struct CalendarObservationCandidate: Equatable, Identifiable {
  var event: CalendarObservedEvent
  var placeName: String?
  var itineraryStopTitle: String?

  var id: String { event.id }
}

@MainActor
@Observable
final class CalendarObservationSpikeModel {
  enum State: Equatable {
    case idle
    case observing
    case accessDenied
    case observed
    case failure(String)
  }

  enum Notice: Equatable, Identifiable {
    case movedOutsideTrip(CalendarObservedEvent)
    case noLongerVisible(String)

    var id: String {
      switch self {
      case let .movedOutsideTrip(event): "moved-\(event.id)"
      case let .noLongerVisible(title): "gone-\(title)"
      }
    }
  }

  @ObservationIgnored @Dependency(\.calendarObservationClient) private var calendarClient
  @ObservationIgnored @Dependency(\.placeMatcher) private var placeMatcher
  @ObservationIgnored @Dependency(\.uuid) private var uuid

  var state: State = .idle
  var candidates: [CalendarObservationCandidate] = []
  var notices: [Notice] = []
  /// Changes only when a user begins a fresh, ephemeral observation. The sheet's
  /// `.task(id:)` consumes the EventKit notification stream for this session and
  /// SwiftUI cancels it on dismissal.
  var observationSessionID: UUID?
  /// Every identifiable event this session has seen *while it was inside* the trip
  /// window, keyed by `eventIdentifier`. This is the baseline the "moved vs.
  /// deleted" safety check compares against. It is deliberately NOT limited to
  /// events that matched an itinerary stop — the ADR-0034 property (loss of
  /// visibility is never a deletion conclusion) must hold for *any* observed event,
  /// and requiring a scheduled-stop match made the gate impossible to exercise.
  /// Events without a stable identifier can be shown but never enter the baseline,
  /// because the spike cannot honestly follow them after they leave the query.
  private var baselineInScope: [String: CalendarObservedEvent] = [:]
  /// The trip the baseline belongs to. This must outlive the sheet's view
  /// lifecycle: the content is gated on a `@FetchAll`-derived `trip` that can
  /// momentarily resolve nil on a foreground re-fetch and tear the sheet down
  /// (firing `.onDisappear`). Keying the reset on trip identity — not on every
  /// `begin()` — keeps the baseline across that churn, which is exactly the
  /// fragility that argues for the durable reconciliation ledger in later slices.
  private var lastObservedTripID: Trip.ID?

  func begin(trip: Trip, plan: TripPlan) async {
    observationSessionID = uuid()
    if lastObservedTripID != trip.id {
      // A genuinely different trip: start a fresh baseline. Re-entering the same
      // trip (including a transient sheet-content rebuild) preserves it.
      baselineInScope = [:]
      lastObservedTripID = trip.id
    }
    candidates = []
    notices = []
    await refresh(trip: trip, plan: plan)
  }

  func refresh(trip: Trip, plan: TripPlan) async {
    guard let scope = scope(for: trip) else {
      state = .failure("This spike only observes dated trips.")
      return
    }
    state = .observing
    do {
      let granted = try await calendarClient.requestFullAccess()
      guard granted, calendarClient.hasFullAccess() else {
        state = .accessDenied
        return
      }

      let events = try calendarClient.events(scope)
      let candidates = await candidates(for: events, plan: plan)
      guard !Task.isCancelled else { return }

      self.candidates = candidates
      // Grow the in-scope baseline with every identifiable event currently in the
      // trip window, so any of them can later be recognized as moved-or-gone.
      for event in events {
        if let identifier = event.eventIdentifier {
          baselineInScope[identifier] = event
        }
      }
      updateNotices(scope: scope, visibleEvents: events)
      state = .observed
    } catch is CancellationError {
      // Sheet dismissal is normal lifecycle cancellation, not a calendar failure.
    } catch {
      state = .failure(error.localizedDescription)
    }
  }

  /// Re-queries after EventKit says its database (including access) changed. This
  /// does not retain an EventKit object: Apple's header says all fetched events are
  /// invalid after the notification, so every pass starts from fresh value snapshots.
  func observeChanges(trip: Trip, plan: TripPlan) async {
    for await _ in calendarClient.changes() {
      guard !Task.isCancelled else { return }
      await refresh(trip: trip, plan: plan)
    }
  }

  func end() {
    // Only stop the EventKit change stream (via the session id the sheet's
    // `.task(id:)` observes). Deliberately keep `baselineInScope`: `.onDisappear`
    // also fires on transient content teardown, and clearing the baseline here is
    // what previously erased the "moved outside trip" comparison mid-session.
    observationSessionID = nil
  }

  private func candidates(
    for events: [CalendarObservedEvent], plan: TripPlan
  ) async -> [CalendarObservationCandidate] {
    var result: [CalendarObservationCandidate] = []
    for event in events {
      guard !Task.isCancelled else { return [] }
      let place = await placeMatcher.match(
        calendarEventTitle: event.title,
        latitude: event.latitude,
        longitude: event.longitude,
        location: event.location
      )
      let stop = matchingStop(
        named: place?.name ?? event.title,
        mapItemIdentifier: place?.mapItemIdentifier,
        in: plan
      )
      result.append(
        CalendarObservationCandidate(
          event: event,
          placeName: place?.name,
          itineraryStopTitle: stop?.content.title
        )
      )
    }
    return result
  }

  /// The spike only displays an obvious candidate; it never establishes a link.
  /// Exact Maps identity wins when both sides have it. The existing PlaceMatching
  /// score is the fallback, so calendar does not grow a second text matcher.
  private func matchingStop(
    named name: String,
    mapItemIdentifier: String?,
    in plan: TripPlan
  ) -> ResolvedStop? {
    plan.scheduled.first { stop in
      guard let idea = stop.idea else { return false }
      if let mapItemIdentifier, idea.mapItemIdentifier == mapItemIdentifier { return true }
      return PlaceMatching.score(
        candidateName: name,
        candidateStreet: "",
        scrapedName: idea.name,
        scrapedStreet: ""
      ) > 0
    }
  }

  private func updateNotices(scope: DateInterval, visibleEvents: [CalendarObservedEvent]) {
    let visibleIdentifiers = Set(visibleEvents.compactMap(\.eventIdentifier))
    notices = baselineInScope
      .sorted { $0.value.startDate < $1.value.startDate }
      .compactMap { identifier, seen -> Notice? in
        // Still in the trip window — nothing to report.
        guard !visibleIdentifiers.contains(identifier) else { return nil }
        if let current = calendarClient.event(identifier), !scope.contains(current.startDate) {
          return .movedOutsideTrip(current)
        }
        // `event(withIdentifier:) == nil` can be a deletion, a changed EventKit
        // identifier, unavailable account, or incomplete sync. Slice 0 proves that
        // this loss of visibility cannot trigger a destructive conclusion.
        return .noLongerVisible(seen.title)
      }
  }

  /// Full first and last civil days, as required by ADR-0034. The exact
  /// trip-zone/floating-time model remains M7 Slice 4; this spike intentionally
  /// exposes the installed EventKit query behavior before making that state durable.
  private func scope(for trip: Trip) -> DateInterval? {
    guard let startDate = trip.startDate else { return nil }
    let calendar = Calendar.current
    let start = calendar.startOfDay(for: startDate)
    guard let end = calendar.date(byAdding: .day, value: trip.lengthInDays, to: start) else {
      return nil
    }
    return DateInterval(start: start, end: end)
  }
}

/// Small, removable M7 gate UI. It is intentionally a read-only diagnostics
/// surface rather than the later reconciliation inbox: no action here writes the
/// app database, links a stop, or changes Calendar.
struct CalendarObservationSpikeSheet: View {
  let model: CalendarObservationSpikeModel
  let trip: Trip
  let plan: TripPlan
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    @Bindable var model = model
    NavigationStack {
      List {
        Section {
          Text("M7 Slice 0 — read-only EventKit observation. Results stay only in memory; nothing is linked, written, or exported.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        if !model.notices.isEmpty {
          Section("Observation Safety") {
            ForEach(model.notices) { notice in
              switch notice {
              case let .movedOutsideTrip(event):
                Text("\(event.title) moved outside this trip's dates. It is not treated as deleted.")
              case let .noLongerVisible(title):
                Text("\(title) is no longer visible to this observation. This is unknown, not a deletion.")
              }
            }
          }
        }

        switch model.state {
        case .idle, .observing:
          Section { ProgressView("Observing shared calendars…") }
        case .accessDenied:
          Section("Calendar Access") {
            Text("Full Calendar access is unavailable. This makes no deletion or plan-change decision.")
          }
        case let .failure(message):
          Section("Observation Failed") { Text(message) }
        case .observed:
          if model.candidates.isEmpty {
            ContentUnavailableView("No events in this trip's dates", systemImage: "calendar")
          } else {
            Section("Observed Events") {
              ForEach(model.candidates) { candidate in
                VStack(alignment: .leading, spacing: 4) {
                  Text(candidate.event.title)
                  Text(candidate.event.calendarTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  if let placeName = candidate.placeName {
                    Text("PlaceMatcher: \(placeName)")
                      .font(.caption)
                  }
                  if let stop = candidate.itineraryStopTitle {
                    Text("Candidate itinerary match: \(stop)")
                      .font(.caption)
                      .foregroundStyle(.green)
                  }
                }
              }
            }
          }
        }
      }
      .navigationTitle("Calendar Observation")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Refresh") {
            Task { await model.refresh(trip: trip, plan: plan) }
          }
          .disabled(model.state == .observing)
        }
      }
      .task { await model.begin(trip: trip, plan: plan) }
      .task(id: model.observationSessionID) {
        guard model.observationSessionID != nil else { return }
        await model.observeChanges(trip: trip, plan: plan)
      }
      // The async `EKEventStoreChanged` stream does not reliably deliver a change
      // that happened while the app was backgrounded (e.g. the edit you just made
      // in Calendar). Re-query deterministically whenever the app returns active.
      .onChange(of: scenePhase) { _, phase in
        if phase == .active {
          Task { await model.refresh(trip: trip, plan: plan) }
        }
      }
      .onDisappear { model.end() }
    }
  }
}
