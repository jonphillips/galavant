import Foundation
import SQLiteData

/// Assigns one of a trip's `MapRegion`s to a specific day (ADR-0012) — the
/// planning unit that scopes the day's idea pool (slice B), labels the day, and
/// frames the day's map *while it has no located stops yet*. A multi-sub-region
/// trip (Provence / Loire / Normandy) names which days sit in which sub-region,
/// independent of where any hotel geocoded.
///
/// Single real foreign key to `Trip` (rides the trip, cascade-deletes with it);
/// `regionID` is a loose UUID, not a SQL FK, per the single-FK sharing rule
/// (ADR-0007). Orphans (region deleted) are tolerated — a missing region just drops
/// out on read, the same as `TripRegion`. At most one row per `(tripID, dayNumber)`:
/// the write path replaces any existing assignment for the day.
@Table
public struct TripDayRegion: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tripID: Trip.ID
  public var dayNumber: Int
  public var regionID: MapRegion.ID

  public init(id: UUID, tripID: Trip.ID, dayNumber: Int, regionID: MapRegion.ID) {
    self.id = id
    self.tripID = tripID
    self.dayNumber = dayNumber
    self.regionID = regionID
  }
}

extension TripDayRegion {
  /// The region assigned to a trip's day, if any.
  public static func regionID(
    forTrip tripID: Trip.ID, day: Int, in db: Database
  ) throws -> MapRegion.ID? {
    try TripDayRegion
      .where { $0.tripID.eq(tripID) && $0.dayNumber.eq(day) }
      .fetchAll(db)
      .first?
      .regionID
  }

  /// Set (or, with `nil`, clear) a day's region — replacing any existing
  /// assignment for that `(trip, day)` so at most one row survives. The day-header
  /// region menu's save.
  public static func setRegion(
    _ regionID: MapRegion.ID?,
    forTrip tripID: Trip.ID,
    day: Int,
    in db: Database
  ) throws {
    try TripDayRegion
      .where { $0.tripID.eq(tripID) && $0.dayNumber.eq(day) }
      .delete()
      .execute(db)
    if let regionID {
      try TripDayRegion.insert {
        TripDayRegion.Draft(id: UUID(), tripID: tripID, dayNumber: day, regionID: regionID)
      }
      .execute(db)
    }
  }
}
