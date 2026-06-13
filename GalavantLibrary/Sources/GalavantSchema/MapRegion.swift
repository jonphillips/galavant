import Foundation
import SQLiteData

/// A named geographic bucket — a saved map viewport ("Virginia", "Copenhagen").
/// Persistent and reused across many trips; ideas belong to it by *coordinate
/// containment*, computed live, never a stored link (so moving a region
/// re-scopes automatically). Hangs off the travel party (ADR-0007 single-FK).
@Table
public struct MapRegion: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name = ""
  public var centerLatitude: Double
  public var centerLongitude: Double
  public var latitudeDelta: Double
  public var longitudeDelta: Double
  public var travelPartyID: TravelParty.ID?

  public init(
    id: UUID,
    name: String = "",
    centerLatitude: Double,
    centerLongitude: Double,
    latitudeDelta: Double,
    longitudeDelta: Double,
    travelPartyID: TravelParty.ID? = nil
  ) {
    self.id = id
    self.name = name
    self.centerLatitude = centerLatitude
    self.centerLongitude = centerLongitude
    self.latitudeDelta = latitudeDelta
    self.longitudeDelta = longitudeDelta
    self.travelPartyID = travelPartyID
  }
}

extension MapRegion {
  /// Whether a coordinate falls within this region's bounds. Pure (no MapKit),
  /// so it's unit-testable and usable in queries. Antimeridian wrap is ignored
  /// — fine for a household planner.
  public func contains(latitude: Double, longitude: Double) -> Bool {
    let latGap: Double = Swift.abs(latitude - centerLatitude)
    let lonGap: Double = Swift.abs(longitude - centerLongitude)
    let latHalf: Double = latitudeDelta / 2
    let lonHalf: Double = longitudeDelta / 2
    return latGap <= latHalf && lonGap <= lonHalf
  }
}
