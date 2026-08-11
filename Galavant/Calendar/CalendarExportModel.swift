import Dependencies
import Foundation
import GalavantPlaces
import GalavantSchema
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

// MARK: - M7 Slice 1 read-only ingest and reconciliation

/// Coordinates a fresh trip-scoped Calendar read, an app-side `PlaceMatcher`
/// pass, and the pure reconciliation ladder. Results are deliberately held only
/// in memory: Slice 1 writes no EventKit record, app record, or local ledger.
@MainActor
@Observable
final class CalendarReconciliationModel {
  enum State: Equatable {
    case idle
    case loading
    case accessDenied
    case loaded
    case failure(String)
  }

  @ObservationIgnored @Dependency(\.calendarIngestionClient) private var calendarClient
  @ObservationIgnored @Dependency(\.placeMatcher) private var placeMatcher

  var state: State = .idle
  var candidates: [CalendarReconciliationCandidate] = []

  func refresh(trip: Trip, plan: TripPlan) async {
    guard let scope = scope(for: trip) else {
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

      let events = try calendarClient.events(scope)
      let ingestedEvents = try await ingest(events)
      candidates = CalendarReconciliation.candidates(for: ingestedEvents, trip: trip, plan: plan)
      state = .loaded
    } catch is CancellationError {
      // Sheet dismissal is normal view-lifecycle cancellation.
    } catch {
      state = .failure(error.localizedDescription)
    }
  }

  private func ingest(_ events: [CalendarObservedEvent]) async throws -> [CalendarIngestedEvent] {
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
      ingested.append(CalendarIngestedEvent(event: event, matchedPlace: matchedPlace))
    }
    return ingested
  }

  /// Full first and last civil days. M7 Slice 4 owns the durable travel-zone and
  /// floating-time model; this read-only slice intentionally makes no such fact.
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
          Text("Calendar is read-only here. These local results do not link, alter, or store anything yet.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        switch model.state {
        case .idle, .loading:
          Section { ProgressView("Reading shared calendars…") }
        case .accessDenied:
          Section("Calendar Access") {
            Text("Full Calendar access is unavailable. Galavant made no deletion or itinerary decision.")
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
      if !unmatched.isEmpty {
        Section("No Itinerary Match") {
          ForEach(unmatched, content: candidateRow)
        }
      }
    }
  }

  private func candidateRow(_ candidate: CalendarReconciliationCandidate) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(candidate.input.event.title)
      Text(candidate.input.event.calendarTitle)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(candidate.input.event.startDate, format: .dateTime.weekday().month().day().hour().minute())
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
    }
  }
}
