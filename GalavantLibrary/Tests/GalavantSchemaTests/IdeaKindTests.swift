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
}
