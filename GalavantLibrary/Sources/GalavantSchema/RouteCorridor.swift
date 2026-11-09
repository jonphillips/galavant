import Foundation

/// Finds saved ideas near the straight route polyline shown on the trip map.
/// This is planning feedback around those drawn lines, not a road route.
public struct RouteCorridor: Equatable, Sendable {
  public struct Match: Equatable, Sendable {
    public var ideaID: Idea.ID
    public var distanceMeters: Double
    /// Fraction of the route's total length, from 0 at its start to 1 at its end.
    public var progress: Double

    public init(ideaID: Idea.ID, distanceMeters: Double, progress: Double) {
      self.ideaID = ideaID
      self.distanceMeters = distanceMeters
      self.progress = progress
    }
  }

  /// Mean Earth radius, used to convert angular coordinates to local meters.
  private static let earthRadiusMeters = 6_371_000.0

  /// Ideas within `widthMeters` of the straight polyline through `route`, ordered
  /// by progress. It measures distance to each segment (not just its endpoints),
  /// using a local equirectangular projection centered on each segment.
  public static func matches(
    route: [TravelEndpoint], ideas: [Idea], widthMeters: Double = 15_000
  ) -> [Match] {
    guard let first = route.first else { return [] }
    let segments = zip(route, route.dropFirst()).map(segment)
    let routeLength = segments.reduce(0) { $0 + $1.length }

    return ideas.compactMap { idea in
      guard let latitude = idea.latitude, let longitude = idea.longitude else { return nil }
      let nearest: (distance: Double, progress: Double)?
      if route.count == 1 {
        let distance = pointDistance(
          latitude: latitude, longitude: longitude,
          centerLatitude: first.latitude, centerLongitude: first.longitude)
        nearest = (distance, 0)
      } else {
        var distanceAlong = 0.0
        var best: (distance: Double, progress: Double)?
        for segment in segments {
          let projection = segment.projection(latitude: latitude, longitude: longitude)
          let progress = routeLength > 0
            ? (distanceAlong + segment.length * projection.fraction) / routeLength
            : 0
          if best == nil || projection.distance < best!.distance {
            best = (projection.distance, progress)
          }
          distanceAlong += segment.length
        }
        nearest = best
      }
      guard let nearest, nearest.distance <= widthMeters else { return nil }
      return Match(ideaID: idea.id, distanceMeters: nearest.distance, progress: nearest.progress)
    }
    .sorted { lhs, rhs in
      if lhs.progress == rhs.progress { return lhs.ideaID.uuidString < rhs.ideaID.uuidString }
      return lhs.progress < rhs.progress
    }
  }

  private struct Segment {
    var centerLatitude: Double
    var centerLongitude: Double
    var fromX: Double
    var fromY: Double
    var dx: Double
    var dy: Double
    var length: Double

    func projection(latitude: Double, longitude: Double) -> (distance: Double, fraction: Double) {
      let point = localPoint(latitude: latitude, longitude: longitude)
      let squaredLength = dx * dx + dy * dy
      let relativeX = point.x - fromX
      let relativeY = point.y - fromY
      let fraction = squaredLength == 0
        ? 0
        : min(1, max(0, (relativeX * dx + relativeY * dy) / squaredLength))
      let nearestX = fromX + fraction * dx
      let nearestY = fromY + fraction * dy
      let offsetX = point.x - nearestX
      let offsetY = point.y - nearestY
      return (sqrt(offsetX * offsetX + offsetY * offsetY), fraction)
    }

    private func localPoint(latitude: Double, longitude: Double) -> (x: Double, y: Double) {
      let radians = Double.pi / 180
      return (
        (longitude - centerLongitude) * radians * RouteCorridor.earthRadiusMeters
          * cos(centerLatitude * radians),
        (latitude - centerLatitude) * radians * RouteCorridor.earthRadiusMeters
      )
    }
  }

  private static func segment(_ endpoints: (TravelEndpoint, TravelEndpoint)) -> Segment {
    let (from, to) = endpoints
    let centerLatitude = (from.latitude + to.latitude) / 2
    let centerLongitude = (from.longitude + to.longitude) / 2
    let radians = Double.pi / 180
    let dx = (to.longitude - from.longitude) * radians * earthRadiusMeters
      * cos(centerLatitude * radians)
    let dy = (to.latitude - from.latitude) * radians * earthRadiusMeters
    let fromX = (from.longitude - centerLongitude) * radians * earthRadiusMeters
      * cos(centerLatitude * radians)
    let fromY = (from.latitude - centerLatitude) * radians * earthRadiusMeters
    return Segment(
      centerLatitude: centerLatitude,
      centerLongitude: centerLongitude,
      fromX: fromX,
      fromY: fromY,
      dx: dx,
      dy: dy,
      length: sqrt(dx * dx + dy * dy))
  }

  private static func pointDistance(
    latitude: Double, longitude: Double, centerLatitude: Double, centerLongitude: Double
  ) -> Double {
    let radians = Double.pi / 180
    let x = (longitude - centerLongitude) * radians * earthRadiusMeters * cos(centerLatitude * radians)
    let y = (latitude - centerLatitude) * radians * earthRadiusMeters
    return sqrt(x * x + y * y)
  }
}
