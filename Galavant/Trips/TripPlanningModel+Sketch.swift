import Foundation
import GalavantSchema
import SQLiteData

/// The trip-sketch surface's state and write actions (ADR-0012,
/// docs/handoff/trip-sketch-design.md): the shape of a trip — how many days, and
/// which region each part sits in — decided before any stop exists.
///
/// The span math is the pure `TripSketch` value type in `GalavantSchema`; what lives
/// here is presentation and persistence. Edits persist **live** (as the rest of the
/// planning surface does — the day-header region chip, the canvas lenses), so a
/// per-span "Add lodging" or "Attach regions…" can hand off to those editors without
/// stranding half-made region assignments behind an unconfirmed sheet.
extension TripPlanningModel {
  /// The current sketch as a pure value — the sheet's working seed. Reads the
  /// trip's length and its per-day region rows directly rather than through `plan`,
  /// which rebuilds the whole join graph.
  var sketch: TripSketch {
    TripSketch(
      lengthInDays: trip?.lengthInDays ?? 1,
      dayRegions: allTripDayRegions.filter { $0.tripID == tripID })
  }

  /// Present the trip-sketch sheet (the "···" menu and the empty-itinerary CTA).
  func sketchTapped() {
    destination = .sketch(TripSketchPresentation())
  }

  /// The `MapRegion` for a span's assigned id, resolved live against the region pool
  /// (ADR-0007 read-time reconciliation — a since-deleted region drops out).
  func region(_ id: MapRegion.ID?) -> MapRegion? {
    guard let id else { return nil }
    return regions.first { $0.id == id }
  }

  /// Persist a whole sketch — its length and its per-day region layout — in one
  /// transaction. `replaceAssignments` rewrites the layout wholesale, so a cleared
  /// day and a day orphaned past a shortened length both fall away here.
  func persistSketch(_ sketch: TripSketch) {
    let tripID = tripID
    let length = sketch.lengthInDays
    let assignments = sketch.assignments()
    withErrorReporting {
      try database.write { db in
        try Trip.setLength(length, tripID: tripID, in: db)
        try TripDayRegion.replaceAssignments(assignments, forTrip: tripID, in: db)
      }
    }
  }

  /// Any lodging stay overlapping a span — shown as a hint on the sketch row so the
  /// region and lodging layers stay legibly distinct but visibly agree.
  func stay(overlapping span: DaySpan) -> ResolvedStay? {
    plan.stays.first { stay in
      stay.stay.checkInDay <= span.endDay && stay.stay.checkOutDay > span.startDay
    }
  }

  /// "Add lodging for these nights" — seed the existing lodging editor to the span
  /// (check-in on its first day, check-out the morning after its last). Reuses the
  /// tested `StaySheet` write path; this only seeds the draft (Q2 of the design
  /// note). Replaces the sketch presentation with the stay editor.
  func addLodging(forSpan span: DaySpan) {
    let length = max(2, trip?.lengthInDays ?? 2)
    let checkIn = min(max(1, span.startDay), length - 1)
    let checkOut = min(max(checkIn + 1, span.endDay + 1), length)
    destination = .stay(StayDraft(checkInDay: checkIn, checkOutDay: checkOut))
  }
}
