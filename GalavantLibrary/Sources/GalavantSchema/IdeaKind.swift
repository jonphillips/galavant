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

  /// Map a MapKit `MKPointOfInterestCategory.rawValue` to a kind, so search-first
  /// capture can pre-fill the kind from what MapKit knows about a place. Keyed on
  /// the raw string (e.g. `"MKPOICategoryRestaurant"`) so this stays pure — the
  /// schema package never imports MapKit and the table is fully testable without
  /// it. Unknown/unmapped categories (including new OS-version additions) return
  /// `nil` → the form falls back to Unspecified. Only well-established categories
  /// are mapped; ambiguous ones are deliberately left to the user.
  public init?(pointOfInterestCategoryRawValue rawValue: String) {
    switch rawValue {
    case "MKPOICategoryRestaurant", "MKPOICategoryBakery", "MKPOICategoryCafe":
      self = .food
    case "MKPOICategoryBrewery", "MKPOICategoryWinery", "MKPOICategoryDistillery":
      self = .drink
    case "MKPOICategoryNightlife":
      self = .nightlife
    case "MKPOICategoryHotel", "MKPOICategoryCampground":
      self = .stay
    case "MKPOICategoryMuseum":
      self = .museum
    case "MKPOICategoryMovieTheater", "MKPOICategoryTheater":
      self = .theater
    case "MKPOICategoryBeach":
      self = .beach
    case "MKPOICategoryPark", "MKPOICategoryNationalPark":
      self = .park
    case "MKPOICategoryHiking", "MKPOICategoryNationalMonument":
      self = .outdoorTrail
    case "MKPOICategoryFoodMarket":
      self = .market
    case "MKPOICategoryStore":
      self = .shop
    case "MKPOICategoryPublicTransport", "MKPOICategoryAirport":
      self = .transit
    case "MKPOICategoryAmusementPark", "MKPOICategoryAquarium", "MKPOICategoryZoo",
      "MKPOICategoryStadium", "MKPOICategoryFitnessCenter", "MKPOICategoryMarina",
      "MKPOICategoryBowling", "MKPOICategoryGoKart", "MKPOICategorySkatePark":
      self = .activity
    case "MKPOICategoryLandmark", "MKPOICategoryCastle", "MKPOICategoryFortress",
      "MKPOICategoryPlanetarium", "MKPOICategoryReligiousSite":
      self = .sight
    default:
      return nil
    }
  }
}
