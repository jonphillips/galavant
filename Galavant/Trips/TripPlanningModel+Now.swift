import Foundation
import GalavantSchema

/// The planning surface's sense of *now*. When the trip is on, planning shouldn't
/// make you scroll to today and select it: the canvas opens on the live day, the
/// chip strip says which day that is, and the whole-trip itinerary is already
/// sitting on it.
///
/// The derivation itself is pure (`TodayProjection.tripDay`, `DayLensSeeding`) and
/// tested in `GalavantSchema`; what lives here is the state those rules drive.
extension TripPlanningModel {
  /// The controlled clock. Everything on this surface that asks "what time is it?"
  /// comes through here rather than `Date.now`, so the behaviour is testable.
  var now: Date { date.now }

  /// The trip day the given instant falls on, or `nil` when the trip is undated or
  /// that instant is outside its span.
  ///
  /// Takes the length from the trip row rather than `plan`, which rebuilds the whole
  /// join graph on every access — this is read on each layout pass.
  func liveDay(at instant: Date) -> Int? {
    guard let trip, let startDate = trip.startDate else { return nil }
    return TodayProjection.tripDay(
      containing: instant, tripStartDate: startDate, lengthInDays: trip.lengthInDays)
  }

  /// The trip day happening right now, or `nil` when the trip isn't underway.
  var liveDay: Int? { liveDay(at: now) }

  /// Seed the day lens to the live day on first appear, so an active trip opens
  /// where you are. One shot (`DayLensSeeding`): a later appearance, or the clock
  /// crossing midnight, never overrides a day the user has since chosen.
  ///
  /// Deliberately no-ops until the trip row has loaded — an unresolved trip would
  /// spend the single seeding opportunity on a trip we know nothing about yet.
  func seedDayLensIfNeeded() {
    guard let trip else { return }
    guard
      let day = dayLensSeeding.seedDay(
        now: now, tripStartDate: trip.startDate, lengthInDays: trip.lengthInDays)
    else { return }
    selectCanvasDay(day)
  }

  /// The day the **whole-trip** itinerary should be sitting on, or `nil` to leave it
  /// where it is.
  ///
  /// Under a lodging lens that's the stay's first day: a stay is a span, so the list
  /// keeps the whole trip (you can still see the nights either side) and simply moves
  /// to where the stay begins. Otherwise it's the live day.
  var itineraryFocusDay: Int? {
    if let canvasSelectedStayID {
      return allTripStays.first { $0.id == canvasSelectedStayID }?.checkInDay
    }
    return liveDay
  }
}
