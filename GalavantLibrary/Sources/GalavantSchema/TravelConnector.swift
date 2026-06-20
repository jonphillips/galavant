import Foundation

/// The result of an MKDirections ETA request between two itinerary stops.
public struct TravelTime: Equatable, Sendable {
  public var seconds: TimeInterval
  public var meters: Double

  public init(seconds: TimeInterval, meters: Double) {
    self.seconds = seconds
    self.meters = meters
  }

  public var formatted: String {
    let minutes = Int(seconds / 60)
    if minutes < 1 { return "< 1 min walk" }
    if minutes < 60 { return "\(minutes) min walk" }
    let h = minutes / 60
    let m = minutes % 60
    return m == 0 ? "\(h) hr walk" : "\(h) hr \(m) min walk"
  }
}

/// A directed coordinate pair — the cache key for ETA results. Uses raw doubles
/// so the schema package stays MapKit-free and the pure core is testable.
public struct LegKey: Hashable, Sendable {
  public var fromLat: Double
  public var fromLon: Double
  public var toLat: Double
  public var toLon: Double

  public init(fromLat: Double, fromLon: Double, toLat: Double, toLon: Double) {
    self.fromLat = fromLat
    self.fromLon = fromLon
    self.toLat = toLat
    self.toLon = toLon
  }
}

/// An interstitial travel-time row between two consecutive itinerary stops.
/// `travelTime` is nil while the ETA is still loading or the leg has no result.
public struct TravelConnector: Identifiable, Equatable, Sendable {
  public var fromStopID: TripIdea.ID
  public var toStopID: TripIdea.ID
  public var travelTime: TravelTime?

  public var id: String { "\(fromStopID)-\(toStopID)" }

  public init(fromStopID: TripIdea.ID, toStopID: TripIdea.ID, travelTime: TravelTime?) {
    self.fromStopID = fromStopID
    self.toStopID = toStopID
    self.travelTime = travelTime
  }
}

/// One row in the itinerary timeline — either a stop or a travel-time connector
/// between two consecutive located stops.
public enum ItineraryItem: Identifiable, Equatable, Sendable {
  case stop(ResolvedStop)
  case connector(TravelConnector)

  public var id: String {
    switch self {
    case .stop(let s): "stop-\(s.id)"
    case .connector(let c): "connector-\(c.id)"
    }
  }
}
