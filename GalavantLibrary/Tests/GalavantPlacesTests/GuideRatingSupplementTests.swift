import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@testable import GalavantPlaces

/// On-demand guide-rating supplement (ADR-0023) — the HITL fallback to ADR-0021's
/// automated guide-link hop. The *judgment* sibling of `FieldSupplement`: it records the
/// guide's rating as a sibling `IdeaEvaluation` (`.official`), never an `Idea` fact, and
/// when the guide page won't render to a plain fetch it returns the URL for the browser.
@MainActor
@Suite struct GuideRatingSupplementTests {
  /// The place's own page — links out to its Michelin guide-detail page, where the ★★★
  /// actually lives (the motivating ADR-0021 shape).
  nonisolated private static let placeHTML = """
    <html><body>
      <h1>Geranium</h1>
      <a href="https://guide.michelin.com/dk/en/restaurant/geranium">See our Michelin page</a>
    </body></html>
    """

  /// The Michelin guide-detail page — its JSON-LD + host text yield ★★★ (mirrors the
  /// recognizer's headline fixture).
  nonisolated private static let guideHTML = """
    <html><head>
    <script type="application/ld+json">{
      "@context": "https://schema.org", "@type": "Restaurant",
      "name": "Geranium", "award": "Three MICHELIN Stars"
    }</script>
    </head><body>
      <h1>Geranium</h1>
      <p>Three MICHELIN Stars · MICHELIN Guide 2024</p>
    </body></html>
    """

  nonisolated private func seedIdea(
    url: String = "https://geranium.dk", party partyID: TravelParty.ID? = nil, in db: Database
  ) throws -> Idea.ID {
    let party = try partyID ?? TravelParty.ensureDefault(in: db).id
    let id = UUID()
    try Idea.insert {
      Idea.Draft(id: id, name: "Geranium", url: url, travelPartyID: party)
    }
    .execute(db)
    return id
  }

  nonisolated private func evaluations(
    forIdea id: Idea.ID, in db: Database
  ) throws -> [IdeaEvaluation] {
    try IdeaEvaluation.where { $0.ideaID.eq(id) }.fetchAll(db)
  }

  @Test("Cheap rung renders the guide page → records ★★★ as an official sibling evaluation")
  func cheapRungRecordsRating() async throws {
    let stamp = Date(timeIntervalSince1970: 1_780_000_000)
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.date = .constant(stamp)
      $0.uuid = .incrementing
      $0.pageFetcher = PageFetcher { url in
        url.host() == "guide.michelin.com" ? Self.guideHTML : Self.placeHTML
      }
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let ideaID = try await database.write { db in try self.seedIdea(in: db) }

      let outcome = await GuideRatingSupplement().supplement(ideaID: ideaID)
      #expect(outcome == .recorded(1))

      let evals = try await database.read { db in try self.evaluations(forIdea: ideaID, in: db) }
      #expect(evals.count == 1)
      #expect(evals.first?.sourceName == "Michelin Guide")
      #expect(evals.first?.nativeDisplay == "★★★")
      #expect(evals.first?.confidence == .official)
    }
  }

  @Test("Guide page that won't render to a plain fetch → needsBrowser, pointed at the guide URL")
  func emptyGuideFetchNeedsBrowser() async throws {
    let guideURL = URL(string: "https://guide.michelin.com/dk/en/restaurant/geranium")!
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.pageFetcher = PageFetcher { url in
        // The place page renders; the guide page is the JS-heavy one the plain fetch
        // can't read (nil).
        url.host() == "guide.michelin.com" ? nil : Self.placeHTML
      }
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let ideaID = try await database.write { db in try self.seedIdea(in: db) }
      let outcome = await GuideRatingSupplement().supplement(ideaID: ideaID)
      #expect(outcome == .needsBrowser(guideURL))
    }
  }

  @Test("A guide page that fetches but carries no rating also needs the browser")
  func renderedButRatinglessNeedsBrowser() async throws {
    let guideURL = URL(string: "https://guide.michelin.com/dk/en/restaurant/geranium")!
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.pageFetcher = PageFetcher { url in
        url.host() == "guide.michelin.com"
          ? "<html><body>Loading…</body></html>" : Self.placeHTML
      }
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let ideaID = try await database.write { db in try self.seedIdea(in: db) }
      let outcome = await GuideRatingSupplement().supplement(ideaID: ideaID)
      #expect(outcome == .needsBrowser(guideURL))
    }
  }

  @Test("No recognized guide link on the page → noGuideLink")
  func noGuideLink() async throws {
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.pageFetcher = PageFetcher { _ in "<html><body><a href=\"https://example.com\">x</a></body></html>" }
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let ideaID = try await database.write { db in try self.seedIdea(in: db) }
      let outcome = await GuideRatingSupplement().supplement(ideaID: ideaID)
      #expect(outcome == .noGuideLink)
    }
  }

  @Test("An idea with no link can't be supplemented → notReady")
  func notReadyWithoutLink() async throws {
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.pageFetcher = PageFetcher { _ in Issue.record("must not fetch with no link"); return nil }
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let ideaID = try await database.write { db in try self.seedIdea(url: "", in: db) }
      let outcome = await GuideRatingSupplement().supplement(ideaID: ideaID)
      #expect(outcome == .notReady)
    }
  }

  @Test("Rung 3 write-back records the rating off a rendered DOM, stamped official")
  func browsedGuideRecordsOfficial() async throws {
    let guideURL = URL(string: "https://guide.michelin.com/dk/en/restaurant/geranium")
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.date = .constant(Date(timeIntervalSince1970: 1_780_000_000))
      $0.uuid = .incrementing
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let ideaID = try await database.write { db in try self.seedIdea(in: db) }

      let recorded = await GuideRatingSupplement()
        .applyBrowsedGuide(html: Self.guideHTML, sourceURL: guideURL, ideaID: ideaID)
      #expect(recorded == 1)

      let evals = try await database.read { db in try self.evaluations(forIdea: ideaID, in: db) }
      #expect(evals.first?.nativeDisplay == "★★★")
      #expect(evals.first?.confidence == .official)
    }
  }

  @Test("Re-recording the same rating is idempotent — the triad de-dup keeps it at one")
  func idempotentOnReapply() async throws {
    let guideURL = URL(string: "https://guide.michelin.com/dk/en/restaurant/geranium")
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.date = .constant(Date(timeIntervalSince1970: 1_780_000_000))
      $0.uuid = .incrementing
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let ideaID = try await database.write { db in try self.seedIdea(in: db) }
      let supplement = GuideRatingSupplement()

      let first = await supplement.applyBrowsedGuide(
        html: Self.guideHTML, sourceURL: guideURL, ideaID: ideaID)
      let second = await supplement.applyBrowsedGuide(
        html: Self.guideHTML, sourceURL: guideURL, ideaID: ideaID)
      #expect(first == 1)
      #expect(second == 0)  // already carried → nothing new

      let evals = try await database.read { db in try self.evaluations(forIdea: ideaID, in: db) }
      #expect(evals.count == 1)
    }
  }
}
