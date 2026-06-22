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
  /// This region as a `MapFraming.Box` — its exact center and span, no padding.
  /// The empty-day camera frame (ADR-0012): a region is a deliberate viewport, so
  /// it's used as drawn rather than grown like a stops crop.
  public var box: MapFraming.Box {
    MapFraming.Box(
      centerLatitude: centerLatitude,
      centerLongitude: centerLongitude,
      latitudeDelta: latitudeDelta,
      longitudeDelta: longitudeDelta
    )
  }

  /// A single framing box bounding all of `regions` (each contributes its two
  /// corners), or nil when empty — the union frame for a multi-region lens (the
  /// pool map's toggled subregions, ADR-0013; the canvas's trip-region fallback).
  /// Pure (reuses `MapFraming.box`), so it's unit-testable.
  public static func boundingBox(of regions: [MapRegion]) -> MapFraming.Box? {
    var corners: [(latitude: Double, longitude: Double)] = []
    for region in regions {
      let halfLat = region.latitudeDelta / 2
      let halfLon = region.longitudeDelta / 2
      corners.append((latitude: region.centerLatitude - halfLat,
                      longitude: region.centerLongitude - halfLon))
      corners.append((latitude: region.centerLatitude + halfLat,
                      longitude: region.centerLongitude + halfLon))
    }
    return MapFraming.box(for: corners)
  }

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
