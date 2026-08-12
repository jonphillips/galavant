import Foundation

/// The transport mode for a travel-time leg. Named cases map to MKDirections
/// transport types in the app layer (no MapKit import here).
public enum TransportMode: String, CaseIterable, Hashable, Sendable {
  case walking, transit, driving

  public var label: String {
    switch self {
    case .walking: "Walking"
    case .transit: "Transit"
    case .driving: "Driving"
    }
  }

  public var systemImageName: String {
    switch self {
    case .walking: "figure.walk"
    case .transit: "tram.fill"
    case .driving: "car.fill"
    }
  }
}

/// The result of an MKDirections ETA request between two itinerary stops.
public struct TravelTime: Equatable, Sendable {
  public var seconds: TimeInterval
  public var meters: Double

  public init(seconds: TimeInterval, meters: Double) {
    self.seconds = seconds
    self.meters = meters
  }

  public func formatted(mode: TransportMode) -> String {
    let minutes = Int(seconds / 60)
    let unit = mode == .walking ? "walk" : mode == .transit ? "transit" : "drive"
    if minutes < 1 { return "< 1 min \(unit)" }
    if minutes < 60 { return "\(minutes) min \(unit)" }
    let h = minutes / 60
    let m = minutes % 60
    return m == 0 ? "\(h) hr \(unit)" : "\(h) hr \(m) min \(unit)"
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

/// A location participating in a travel-time connector. Keeping the resolved
/// title and coordinate on the value lets a base stay and a regular stop share
/// exactly one direction-row representation.
public struct TravelEndpoint: Identifiable, Equatable, Sendable {
  public var id: String
  public var title: String
  public var latitude: Double
  public var longitude: Double

  public init(id: String, title: String, latitude: Double, longitude: Double) {
    self.id = id
    self.title = title
    self.latitude = latitude
    self.longitude = longitude
  }
}

/// An interstitial travel-time row between two consecutive itinerary locations.
/// `travelTime` is nil while the ETA is loading or unavailable.
public struct TravelConnector: Identifiable, Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// Directions between consecutive scheduled itinerary stops.
    case betweenStops
    /// Directions from a day's unambiguous lodging base to its first stop.
    case fromLodging
    /// A direct same-day lodging change with no stops in between.
    case betweenLodgings
  }

  public var from: TravelEndpoint
  public var to: TravelEndpoint
  public var leg: LegKey
  public var mode: TransportMode
  public var travelTime: TravelTime?
  public var kind: Kind

  public var id: String { "\(from.id)-\(to.id)" }

  public init(
    from: TravelEndpoint, to: TravelEndpoint,
    leg: LegKey, mode: TransportMode, travelTime: TravelTime?,
    kind: Kind = .betweenStops
  ) {
    self.from = from
    self.to = to
    self.leg = leg
    self.mode = mode
    self.travelTime = travelTime
    self.kind = kind
  }
}

/// One row in the itinerary timeline — a stop, a travel-time connector between
/// two consecutive located stops, or the "Now" marker divider.
public enum ItineraryItem: Identifiable, Equatable, Sendable {
  case stop(ResolvedStop)
  /// A fully shared Calendar-originated obligation with no itinerary-place match.
  case calendarConstraint(CalendarTripConstraint)
  case connector(TravelConnector)
  /// A divider that reads "Now" — inserted at the current moment in time within
  /// today's day section. Only appears on dated trips while the trip is active.
  case nowMarker
  /// The check-in boundary of a stay, on its `checkInDay` — a timeline event
  /// sorted by the stay's (optional) check-in time, default evening (ADR-0011).
  case checkIn(ResolvedStay)
  /// The check-out boundary of a stay, on its `checkOutDay` — sorted by the stay's
  /// (optional) check-out time, default morning.
  case checkOut(ResolvedStay)
  /// A persistent "you're based here" row on a *middle* day a stay covers (neither
  /// its check-in nor check-out day) — the home base as a real timeline row rather
  /// than a header chip (ADR-0011, promoted). Sorts to the top of the day.
  case homeBase(ResolvedStay)

  public var id: String {
    switch self {
    case .stop(let s): "stop-\(s.id)"
    case .calendarConstraint(let constraint): "calendarConstraint-\(constraint.id)"
    case .connector(let c): "connector-\(c.id)"
    case .nowMarker: "now-marker"
    case .checkIn(let s): "checkIn-\(s.id)"
    case .checkOut(let s): "checkOut-\(s.id)"
    case .homeBase(let s): "homeBase-\(s.id)"
    }
  }
}
