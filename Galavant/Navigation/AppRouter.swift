import Dependencies
import GalavantAI
import GalavantSchema
import SQLiteData
import SwiftUI

enum IdeasHandoff: Equatable {
  case browse(tripID: Trip.ID, regionID: MapRegion.ID?)
  case guide(tripID: Trip.ID, regionID: MapRegion.ID)
}

/// A request to open the Ideas screen from the itinerary. `id` changes per request
/// so the same hand-off can be re-sent and observed.
struct IdeasScopeRequest: Equatable, Identifiable {
  let id = UUID()
  var handoff: IdeasHandoff
}

/// App-level navigation coordinator: which top-level screen is showing, plus any
/// pending cross-screen hand-off. Owned by `AppContainer`, read from the
/// environment. Keeping this tiny and explicit (not a god-object) — it carries only
/// what genuinely crosses screen boundaries.
@MainActor
@Observable
final class AppRouter {
  var selection: AppScreen? = .trips
  /// The open trip, owned here (above the screen) so flipping to Ideas and back
  /// reopens it — the iPad detail rebuilds on selection change, which would
  /// otherwise drop the push. Driven via `navigationDestination(item:)` rather than
  /// a bound path (a bound path traps the split-view column on teardown).
  var openTrip: Trip?
  /// Set by the itinerary to send the user to the Ideas shopping surface scoped to
  /// a trip (+ a day's region); consumed and cleared by `IdeasScreen` (ADR-0013).
  var ideasScope: IdeasScopeRequest?
  /// The open Evaluate workspace, owned here (above the section) so switching sections
  /// and coming back — e.g. ⌘4 — reopens it instead of dropping to the queue root,
  /// exactly as `openTrip` does for a trip. Driven via `navigationDestination(item:)`.
  var openEvaluateEntry: EvaluateQueueEntry?

  /// Planning models cached per trip so a trip's in-trip state (day lens, sheet tab,
  /// selection, ETA cache) survives the same rebuild `openTrip` guards the push
  /// against. `@ObservationIgnored` — it's a cache vended *during* view body, so it
  /// must not register as observed state being mutated mid-update.
  @ObservationIgnored private var planningModels: [Trip.ID: TripPlanningModel] = [:]

  @ObservationIgnored @Dependency(\.defaultDatabase) private var database

  /// Reopen where a scene was when iPadOS killed it in the background: the section,
  /// and the open trip — re-fetched by id, so one deleted meanwhile just stays
  /// closed. Idempotent: it never overrides a trip that's already open.
  func restore(selection: AppScreen?, openTripID: Trip.ID?) {
    if let selection { self.selection = selection }
    guard openTrip == nil, let openTripID else { return }
    openTrip = withErrorReporting {
      try database.read { db in try Trip.find(openTripID).fetchOne(db) }
    } ?? nil
  }

  /// The (cached) planning model for a trip — stable across screen flips.
  func planningModel(for trip: Trip) -> TripPlanningModel {
    if let existing = planningModels[trip.id] { return existing }
    let model = TripPlanningModel(tripID: trip.id)
    planningModels[trip.id] = model
    return model
  }

  /// Jump to the Ideas shopping surface scoped to a trip and optional day region.
  func browseIdeas(forTrip tripID: Trip.ID, regionID: MapRegion.ID?) {
    ideasScope = IdeasScopeRequest(handoff: .browse(tripID: tripID, regionID: regionID))
    selection = .ideas
  }

  /// Open a region's Guide with the trip selected as its preferred lens.
  func openGuide(forTrip tripID: Trip.ID, regionID: MapRegion.ID) {
    ideasScope = IdeasScopeRequest(handoff: .guide(tripID: tripID, regionID: regionID))
    selection = .ideas
  }
}
