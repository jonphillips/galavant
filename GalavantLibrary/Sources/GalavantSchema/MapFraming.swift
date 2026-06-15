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
  /// Breathing room kept between a just-revealed point and the edge it panned in
  /// from, as a fraction of the visible span — so it isn't flush (and clipped).
  public static let revealMargin = 0.15
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

  /// The minimal camera shift to bring `target` inside the visible `box`, keeping
  /// the current span (zoom). Returns the new center, or `nil` when `target` is
  /// already on screen — so tapping a stop that's already visible never yanks the
  /// map. Each axis moves *independently and only if off-screen*: an axis already
  /// in view stays put (truly minimal); an off-screen axis pans the least amount
  /// to land `margin`·span inside the edge it entered from (so it isn't clipped).
  ///
  /// `bottomInset` (0…1) is the southern fraction of the box obscured by a bottom
  /// sheet (iPhone): a stop that's *geometrically* on screen but down in that band
  /// is *visually* hidden behind the sheet, so the usable bottom edge sits that
  /// much further north and such a stop is panned up into the clear. With the
  /// default 0 (iPad's unobscured map) the behaviour is the strict minimum pan.
  public static func reveal(
    target: (latitude: Double, longitude: Double),
    in box: Box,
    margin: Double = revealMargin,
    bottomInset: Double = 0
  ) -> (latitude: Double, longitude: Double)? {
    let halfLat = box.latitudeDelta / 2
    let halfLon = box.longitudeDelta / 2
    let insetLat = box.latitudeDelta * margin
    let insetLon = box.longitudeDelta * margin
    // The sheet hides the southern `bottomInset` slice, lifting the usable bottom
    // edge north by that much; the top edge (and longitude) are unobscured.
    let obscuredLat = box.latitudeDelta * bottomInset
    var centerLat = box.centerLatitude
    var centerLon = box.centerLongitude
    if target.latitude > box.centerLatitude + halfLat {
      centerLat = target.latitude - halfLat + insetLat
    } else if target.latitude < box.centerLatitude - halfLat + obscuredLat {
      centerLat = target.latitude + halfLat - obscuredLat - insetLat
    }
    if target.longitude > box.centerLongitude + halfLon {
      centerLon = target.longitude - halfLon + insetLon
    } else if target.longitude < box.centerLongitude - halfLon {
      centerLon = target.longitude + halfLon - insetLon
    }
    if centerLat == box.centerLatitude, centerLon == box.centerLongitude {
      return nil
    }
    return (latitude: centerLat, longitude: centerLon)
  }
}
