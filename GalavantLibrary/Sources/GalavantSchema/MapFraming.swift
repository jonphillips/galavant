import Foundation

/// Pure map-framing math: fit a set of coordinates into a center+span box for
/// camera framing, with **no MapKit dependency** (so it's unit-testable). The
/// view layer wraps `Box` in an `MKCoordinateRegion`. Mines V2's
/// `MapUtilities.coordinateRegion(for:)`, reduced to plain doubles. Antimeridian
/// wrap is ignored — fine for a household planner.
public enum MapFraming {
  /// A center coordinate and the lat/lon span that bounds a set of points.
  public struct Box: Equatable, Sendable {
    public var centerLatitude: Double
    public var centerLongitude: Double
    public var latitudeDelta: Double
    public var longitudeDelta: Double

    public init(
      centerLatitude: Double,
      centerLongitude: Double,
      latitudeDelta: Double,
      longitudeDelta: Double
    ) {
      self.centerLatitude = centerLatitude
      self.centerLongitude = centerLongitude
      self.latitudeDelta = latitudeDelta
      self.longitudeDelta = longitudeDelta
    }
  }

  /// The span applied to a single point (which has no extent of its own) — a
  /// neighbourhood-scale zoom so a lone pin isn't framed at world scale.
  public static let singlePointDelta = 0.02
  /// Multiplier on the raw extent so pins don't sit flush against the map edges.
  public static let padding = 1.3
  /// Floor on a multi-point span so two near-identical points don't frame so
  /// tightly the map zooms to street level.
  public static let minimumDelta = 0.005

  /// Bounding box for `coordinates`, or `nil` when empty. A single point → a
  /// default span centred on it; multiple points → the lat/lon extent grown by
  /// `padding`, floored at `minimumDelta`.
  public static func box(
    for coordinates: [(latitude: Double, longitude: Double)]
  ) -> Box? {
    guard let first = coordinates.first else { return nil }
    var minLat = first.latitude, maxLat = first.latitude
    var minLon = first.longitude, maxLon = first.longitude
    for c in coordinates.dropFirst() {
      minLat = Swift.min(minLat, c.latitude)
      maxLat = Swift.max(maxLat, c.latitude)
      minLon = Swift.min(minLon, c.longitude)
      maxLon = Swift.max(maxLon, c.longitude)
    }
    let centerLat = (minLat + maxLat) / 2
    let centerLon = (minLon + maxLon) / 2
    if coordinates.count == 1 {
      return Box(
        centerLatitude: centerLat,
        centerLongitude: centerLon,
        latitudeDelta: singlePointDelta,
        longitudeDelta: singlePointDelta
      )
    }
    return Box(
      centerLatitude: centerLat,
      centerLongitude: centerLon,
      latitudeDelta: Swift.max((maxLat - minLat) * padding, minimumDelta),
      longitudeDelta: Swift.max((maxLon - minLon) * padding, minimumDelta)
    )
  }
}
