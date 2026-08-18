import Foundation
import SQLiteData

/// A device-local choice for one directed itinerary leg. Endpoint identities
/// deliberately avoid coordinates so alternatives and stop moves can preserve a
/// logical slot's chosen mode while the ETA cache continues to use `LegKey`.
@Table
public struct TripTravelModeOverride: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tripID: Trip.ID
  public var fromEndpointID: String
  public var toEndpointID: String
  public var transportMode: String

  public init(id: UUID, tripID: Trip.ID, leg: LegIdentity, mode: TransportMode) {
    self.id = id
    self.tripID = tripID
    fromEndpointID = leg.from
    toEndpointID = leg.to
    transportMode = mode.rawValue
  }

  public var legIdentity: LegIdentity {
    LegIdentity(from: fromEndpointID, to: toEndpointID)
  }

  public var mode: TransportMode? { TransportMode(rawValue: transportMode) }
}

extension TripTravelModeOverride {
  /// Replace the selected mode for one leg. Replacing rather than appending keeps
  /// the common path to one local row per `(trip, legIdentity)`.
  public static func setMode(
    _ mode: TransportMode,
    for leg: LegIdentity,
    tripID: Trip.ID,
    in db: Database
  ) throws {
    try TripTravelModeOverride
      .where {
        $0.tripID.eq(tripID)
          && $0.fromEndpointID.eq(leg.from)
          && $0.toEndpointID.eq(leg.to)
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
