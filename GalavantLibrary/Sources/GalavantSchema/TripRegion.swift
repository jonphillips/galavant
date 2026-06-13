import Foundation
import SQLiteData

/// Associates a trip with the map regions it spans — the persistent planning
/// "lens" that pre-scopes the Add pool (ADR-0004). Single real foreign key to
/// `Trip` (rides the trip, cascade-deletes with it); `regionID` is a loose UUID,
/// not a SQL FK, per the single-FK sharing rule (ADR-0007). Orphans (region
/// deleted) are tolerated — containment is recomputed live and a missing region
/// just drops out of the union.
@Table
public struct TripRegion: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tripID: Trip.ID
  public var regionID: MapRegion.ID

  public init(id: UUID, tripID: Trip.ID, regionID: MapRegion.ID) {
    self.id = id
    self.tripID = tripID
    self.regionID = regionID
  }
}

extension TripRegion {
  /// The region ids currently associated with a trip.
  public static func regionIDs(forTrip tripID: Trip.ID, in db: Database) throws -> [MapRegion.ID] {
    try TripRegion.where { $0.tripID.eq(tripID) }.fetchAll(db).map(\.regionID)
  }

  /// Reconcile a trip's regions to exactly `regionIDs` (insert the new, delete
  /// the dropped) — the form's multi-select save.
  public static func setRegions(
    _ regionIDs: Set<MapRegion.ID>,
    forTrip tripID: Trip.ID,
    in db: Database
  ) throws {
    let existing = Set(try TripRegion.regionIDs(forTrip: tripID, in: db))
    for regionID in regionIDs.subtracting(existing) {
      try TripRegion.insert {
        TripRegion.Draft(id: UUID(), tripID: tripID, regionID: regionID)
      }
      .execute(db)
    }
    let removed = existing.subtracting(regionIDs)
    if !removed.isEmpty {
      try TripRegion
        .where { $0.tripID.eq(tripID) && $0.regionID.in(Array(removed)) }
        .delete()
        .execute(db)
    }
  }
}
