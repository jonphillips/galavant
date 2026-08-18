import Foundation

/// A complete geographic coordinate used by the trip read-model. Keeping the
/// pair together means a resolved stop is either located or location-less.
public struct TripCoordinate: Equatable, Sendable {
  public let latitude: Double
  public let longitude: Double

  public init(latitude: Double, longitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
  }
}
