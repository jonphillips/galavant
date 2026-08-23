import Dependencies
import Foundation
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
