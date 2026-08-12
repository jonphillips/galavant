import Foundation
import SQLiteData

/// A shared choice for one directed itinerary leg. The coordinates deliberately
/// match `LegKey`: an override belongs to the route, not a transient timeline row,
/// so it survives reopening the trip and syncs to the other planner.
@Table
public struct TripTravelModeOverride: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tripID: Trip.ID
  public var fromLat: Double
  public var fromLon: Double
  public var toLat: Double
  public var toLon: Double
  public var transportMode: String

  public init(id: UUID, tripID: Trip.ID, leg: LegKey, mode: TransportMode) {
    self.id = id
    self.tripID = tripID
    fromLat = leg.fromLat
    fromLon = leg.fromLon
    toLat = leg.toLat
    toLon = leg.toLon
    transportMode = mode.rawValue
  }

  public var leg: LegKey {
    LegKey(fromLat: fromLat, fromLon: fromLon, toLat: toLat, toLon: toLon)
  }

  public var mode: TransportMode? { TransportMode(rawValue: transportMode) }
}

extension TripTravelModeOverride {
  /// Replace the selected mode for one leg. Replacing rather than appending keeps
  /// the common path to one synced row per `(trip, leg)`.
  public static func setMode(
    _ mode: TransportMode,
    for leg: LegKey,
    tripID: Trip.ID,
    in db: Database
  ) throws {
    try TripTravelModeOverride
      .where {
        $0.tripID.eq(tripID)
          && $0.fromLat.eq(leg.fromLat)
          && $0.fromLon.eq(leg.fromLon)
          && $0.toLat.eq(leg.toLat)
          && $0.toLon.eq(leg.toLon)
      }
      .delete()
      .execute(db)
    try TripTravelModeOverride.insert {
      TripTravelModeOverride.Draft(
        TripTravelModeOverride(id: UUID(), tripID: tripID, leg: leg, mode: mode)
      )
    }
    .execute(db)
  }
}
