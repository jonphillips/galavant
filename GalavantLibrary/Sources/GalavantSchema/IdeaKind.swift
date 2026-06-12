import SQLiteData

/// What an idea *is* — the taxonomy that lets the pool stay neutral while a
/// kind carries the flavor. Seeded from V1/V2's POICategory; string raw values
/// are stable identifiers, so never change one after it ships.
public enum IdeaKind: String, QueryBindable, CaseIterable, Sendable {
  case sight
  case food
  case drink
  case stay
  case tour
  case activity
  case beach
  case park
  case outdoorTrail
  case museum
  case theater
  case nightlife
  case shop
  case market
  case transit

  public var label: String {
    switch self {
    case .sight: "Sight"
    case .food: "Food"
    case .drink: "Drink"
    case .stay: "Stay"
    case .tour: "Tour"
    case .activity: "Activity"
    case .beach: "Beach"
    case .park: "Park"
    case .outdoorTrail: "Trail"
    case .museum: "Museum"
    case .theater: "Theater"
    case .nightlife: "Nightlife"
    case .shop: "Shop"
    case .market: "Market"
    case .transit: "Transit"
    }
  }

  public var systemImage: String {
    switch self {
    case .sight: "binoculars"
    case .food: "fork.knife"
    case .drink: "wineglass"
    case .stay: "bed.double"
    case .tour: "figure.walk"
    case .activity: "figure.run"
    case .beach: "beach.umbrella"
    case .park: "tree"
    case .outdoorTrail: "mountain.2"
    case .museum: "building.columns"
    case .theater: "theatermasks"
    case .nightlife: "music.note"
    case .shop: "bag"
    case .market: "basket"
    case .transit: "tram"
    }
  }
}
