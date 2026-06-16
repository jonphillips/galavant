import Foundation

/// The schema.org property vocabulary, distilled from the V1 server's ~260-line
/// mapping and ported **as data** (it's the knowledge, not the code). Shared by
/// the JSON-LD and HTML-microdata passes, which speak the same property names.
enum SchemaOrg {
  /// Property names that map directly to a single voted attribute.
  static let scalarProperties: [String: PageAttribute] = [
    "name": .title,
    "legalName": .title,
    "description": .summary,
    "telephone": .phone,
    "email": .email,
    "url": .websiteURL,
  ]

  /// `PostalAddress` sub-properties → voted address attributes.
  static let addressProperties: [String: PageAttribute] = [
    "streetAddress": .street,
    "addressLocality": .locality,
    "addressRegion": .region,
    "postalCode": .postalCode,
    "addressCountry": .country,
  ]

  /// `GeoCoordinates` sub-properties → voted coordinate attributes.
  static let geoProperties: [String: PageAttribute] = [
    "latitude": .latitude,
    "longitude": .longitude,
  ]

  /// schema.org `@type`s we treat as place-like — used to order specificity and
  /// to know an object is worth mining. More specific types should out-vote
  /// generic ones, so they're listed least → most specific.
  static let placeTypes: [String] = [
    "Thing", "Organization", "Place", "LocalBusiness", "CivicStructure",
    "TouristAttraction", "FoodEstablishment", "Restaurant", "CafeOrCoffeeShop",
    "BarOrPub", "LodgingBusiness", "Hotel", "BedAndBreakfast", "Museum", "Park",
  ]
}
