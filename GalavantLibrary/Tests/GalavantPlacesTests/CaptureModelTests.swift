import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@testable import GalavantPlaces

@MainActor
@Suite struct CaptureModelTests {
  private static let restaurantHTML = """
    <html><head>
    <script type="application/ld+json">{
      "@context": "https://schema.org",
      "@type": "Restaurant",
      "name": "Noma",
      "description": "Nordic tasting menu.",
      "url": "https://noma.dk",
      "geo": { "@type": "GeoCoordinates", "latitude": 55.6839, "longitude": 12.6109 }
    }</script>
    </head><body></body></html>
    """

  private static let nameOnlyHTML = """
    <html><head><meta property="og:title" content="Noma Restaurant"></head><body></body></html>
    """

  @Test("prepare parses the page and fills the editable draft")
  func prepareFillsDraft() async {
    await withDependencies {
      try? $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.placeMatcher = .testValue  // scraped coordinates are authoritative anyway
    } operation: {
      let model = CaptureModel(
        html: Self.restaurantHTML, sourceURL: URL(string: "https://www.yelp.com/biz/noma")
      )
      await model.prepare()

      #expect(model.phase == .ready)
      #expect(model.draft.name == "Noma")
      #expect(model.draft.notes == "Nordic tasting menu.")
      #expect(model.draft.kind == .food)
      #expect(model.draft.url == "https://noma.dk")
      #expect(model.draft.latitude == 55.6839)
      #expect(model.draft.longitude == 12.6109)
      // The unconsumed second-hop target is preserved for app-side enrichment.
      #expect(model.captured?.websiteURL == URL(string: "https://noma.dk"))
    }
  }

  @Test("prepare fills a missing coordinate from the Apple Maps match")
  func prepareFillsCoordinateFromMatch() async {
    await withDependencies {
      try? $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.placeMatcher = PlaceMatcher(
        geocode: { _ in nil },
        search: { _ in [Place(id: UUID(), name: "Noma", latitude: 55.6839, longitude: 12.6109)] }
      )
    } operation: {
      let model = CaptureModel(html: Self.nameOnlyHTML, sourceURL: nil)
      await model.prepare()
      #expect(model.draft.latitude == 55.6839)
      #expect(model.draft.longitude == 12.6109)
    }
  }

  @Test("save inserts the idea under the default travel party")
  func saveInsertsUnderDefaultParty() async throws {
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.placeMatcher = .testValue
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let model = CaptureModel(html: Self.restaurantHTML, sourceURL: nil)
      await model.prepare()
      await model.save()

      #expect(model.phase == .saved)
      let ideas = try await database.read { db in try Idea.all.fetchAll(db) }
      #expect(ideas.count == 1)
      let idea = try #require(ideas.first)
      #expect(idea.name == "Noma")
      #expect(idea.kind == .food)
      #expect(idea.travelPartyID != nil)

      let parties = try await database.read { db in try TravelParty.all.fetchAll(db) }
      #expect(parties.count == 1)
      #expect(idea.travelPartyID == parties.first?.id)
    }
  }
}
