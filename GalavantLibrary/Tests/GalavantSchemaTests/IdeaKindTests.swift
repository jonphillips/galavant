import GalavantSchema
import Testing

@Suite struct IdeaKindTests {
  @Test(
    "MapKit POI categories map to kinds",
    arguments: [
      ("MKPOICategoryRestaurant", IdeaKind.food),
      ("MKPOICategoryCafe", .food),
      ("MKPOICategoryBakery", .food),
      ("MKPOICategoryBrewery", .drink),
      ("MKPOICategoryWinery", .drink),
      ("MKPOICategoryNightlife", .nightlife),
      ("MKPOICategoryHotel", .stay),
      ("MKPOICategoryMuseum", .museum),
      ("MKPOICategoryMovieTheater", .theater),
      ("MKPOICategoryBeach", .beach),
      ("MKPOICategoryNationalPark", .park),
      ("MKPOICategoryFoodMarket", .market),
      ("MKPOICategoryStore", .shop),
      ("MKPOICategoryAirport", .transit),
      ("MKPOICategoryZoo", .activity),
      ("MKPOICategoryLandmark", .sight),
    ]
  )
  func known(rawValue: String, expected: IdeaKind) {
    #expect(IdeaKind(pointOfInterestCategoryRawValue: rawValue) == expected)
  }

  @Test("Unknown or future categories fall back to nil")
  func unknown() {
    #expect(IdeaKind(pointOfInterestCategoryRawValue: "MKPOICategorySomethingNew") == nil)
    #expect(IdeaKind(pointOfInterestCategoryRawValue: "") == nil)
  }

  @Test(
    "schema.org types map to kinds",
    arguments: [
      ("Restaurant", IdeaKind.food),
      ("CafeOrCoffeeShop", .food),
      ("BarOrPub", .drink),
      ("Winery", .drink),
      ("Hotel", .stay),
      ("BedAndBreakfast", .stay),
      ("Museum", .museum),
      ("ArtGallery", .museum),
      ("MovieTheater", .theater),
      ("Beach", .beach),
      ("NationalPark", .park),
      ("TouristAttraction", .sight),
      ("Castle", .sight),
      ("Zoo", .activity),
      ("Store", .shop),
      ("FarmersMarket", .market),
      ("Airport", .transit),
    ]
  )
  func schemaOrgKnown(type: String, expected: IdeaKind) {
    #expect(IdeaKind(schemaOrgType: type) == expected)
  }

  @Test("Generic or unknown schema.org types fall back to nil")
  func schemaOrgGeneric() {
    #expect(IdeaKind(schemaOrgType: "Thing") == nil)
    #expect(IdeaKind(schemaOrgType: "Organization") == nil)
    #expect(IdeaKind(schemaOrgType: "LocalBusiness") == nil)
    #expect(IdeaKind(schemaOrgType: "Place") == nil)
    #expect(IdeaKind(schemaOrgType: "") == nil)
  }

  @Test("Most-specific type wins; an all-generic list yields nil")
  func schemaOrgMostSpecific() {
    #expect(IdeaKind(schemaOrgTypes: ["Restaurant", "LocalBusiness"]) == .food)
    #expect(IdeaKind(schemaOrgTypes: ["LocalBusiness", "Restaurant"]) == .food)
    #expect(IdeaKind(schemaOrgTypes: ["Organization", "Place", "Thing"]) == nil)
    #expect(IdeaKind(schemaOrgTypes: []) == nil)
  }
}
