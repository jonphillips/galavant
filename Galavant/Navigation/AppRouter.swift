import GalavantSchema
import SwiftUI

/// A request to open the Ideas screen scoped to a trip, optionally pre-toggling a
/// day's region — the itinerary "Browse ideas for this day" hand-off (ADR-0013, the
/// redefined ADR-0012 slice B). `id` changes per request so the same scope can be
/// re-sent and observed.
struct IdeasScopeRequest: Equatable, Identifiable {
  let id = UUID()
  var tripID: Trip.ID
  var regionID: MapRegion.ID?
}

/// App-level navigation coordinator: which top-level screen is showing, plus any
/// pending cross-screen hand-off. Owned by `AppContainer`, read from the
/// environment. Keeping this tiny and explicit (not a god-object) — it carries only
/// what genuinely crosses screen boundaries.
@MainActor
@Observable
final class AppRouter {
  var selection: AppScreen? = .ideas
  /// The open trip, owned here (above the screen) so flipping to Ideas and back
  /// reopens it — the iPad detail rebuilds on selection change, which would
  /// otherwise drop the push. Driven via `navigationDestination(item:)` rather than
  /// a bound path (a bound path traps the split-view column on teardown).
  var openTrip: Trip?
  /// Set by the itinerary to send the user to the Ideas shopping surface scoped to
  /// a trip (+ a day's region); consumed and cleared by `IdeasScreen` (ADR-0013).
  var ideasScope: IdeasScopeRequest?

  /// Planning models cached per trip so a trip's in-trip state (day lens, sheet tab,
  /// selection, ETA cache) survives the same rebuild `openTrip` guards the push
  /// against. `@ObservationIgnored` — it's a cache vended *during* view body, so it
  /// must not register as observed state being mutated mid-update.
  @ObservationIgnored private var planningModels: [Trip.ID: TripPlanningModel] = [:]

  /// The (cached) planning model for a trip — stable across screen flips.
  func planningModel(for trip: Trip) -> TripPlanningModel {
    if let existing = planningModels[trip.id] { return existing }
    let model = TripPlanningModel(tripID: trip.id)
    planningModels[trip.id] = model
    return model
  }

  /// Jump to the Ideas screen scoped to a trip, optionally pre-toggling a region —
  /// the itinerary's browse-for-this-day hand-off.
  func browseIdeas(forTrip tripID: Trip.ID, regionID: MapRegion.ID?) {
    ideasScope = IdeasScopeRequest(tripID: tripID, regionID: regionID)
    selection = .ideas
  }
}
