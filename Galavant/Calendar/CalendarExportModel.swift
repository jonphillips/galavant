import Dependencies
import Foundation
import GalavantSchema

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
