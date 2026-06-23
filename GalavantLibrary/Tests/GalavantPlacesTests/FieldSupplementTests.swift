import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@testable import GalavantPlaces

/// On-demand field supplement (ADR-0016 §2): the cheapest-source ladder fills an
/// idea's opening hours and stamps provenance; hours land on `Idea` (facts), never
/// `IdeaEvaluation`. MapKit (rung 1) has no hours API on iOS 27, so the tested path
/// is the official-site fetch (rung 2) + the HITL write-back (rung 3).
@MainActor
@Suite struct FieldSupplementTests {
  /// A site whose JSON-LD carries an opening-hours rule the parser already mines.
  nonisolated private static let siteHTML = """
    <html><head><script type="application/ld+json">{
      "@context": "https://schema.org", "@type": "Restaurant", "name": "Spot",
      "openingHours": "Tu-Sa 17:00-23:00"
    }</script></head><body></body></html>
    """

  nonisolated private func seedIdea(url: String = "https://spot.example", in db: Database) throws -> Idea.ID {
    let party = try TravelParty.ensureDefault(in: db)
    let id = UUID()
    try Idea.insert {
      Idea.Draft(id: id, name: "Spot", url: url, travelPartyID: party.id)
    }
    .execute(db)
    return id
  }

  @Test("Rung 2 fills hours from the place's own site, stamped official")
  func officialSiteFillsHours() async throws {
    let stamp = Date(timeIntervalSince1970: 1_780_000_000)
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.date = .constant(stamp)
      $0.pageFetcher = PageFetcher { _ in Self.siteHTML }
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let ideaID = try await database.write { db in try self.seedIdea(in: db) }

      let outcome = await FieldSupplement().supplementHours(ideaID: ideaID)
      #expect(outcome == .filled(.official))

      let idea = try #require(try await database.read { db in try Idea.find(ideaID).fetchOne(db) })
      #expect(idea.openingHours == "Tu-Sa 17:00-23:00")
      #expect(idea.hoursProvenance == .official)
      #expect(idea.hoursVerifiedAt == stamp)
    }
  }

  @Test("Rung 1 (MapKit) wins when a probe yields hours")
  func mapKitProbeWinsWhenAvailable() async throws {
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.date = .constant(Date(timeIntervalSince1970: 1_780_000_000))
      // Simulate a future iOS where MapKit hands us hours — the official-site fetch
      // must never be consulted once rung 1 succeeds.
      $0.mapItemHoursProbe = MapItemHoursProbe { _, _, _ in "Daily 09:00-17:00" }
      $0.pageFetcher = PageFetcher { _ in Issue.record("rung 2 must not run"); return nil }
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let ideaID = try await database.write { db in
        let party = try TravelParty.ensureDefault(in: db)
        let id = UUID()
        try Idea.insert {
          Idea.Draft(id: id, name: "Spot", latitude: 1, longitude: 2, travelPartyID: party.id)
        }
        .execute(db)
        return id
      }
      let outcome = await FieldSupplement().supplementHours(ideaID: ideaID)
      #expect(outcome == .filled(.official))
      let idea = try #require(try await database.read { db in try Idea.find(ideaID).fetchOne(db) })
      #expect(idea.openingHours == "Daily 09:00-17:00")
    }
  }

  @Test("An idea that already has hours is left alone unless forced")
  func alreadyPresentIsLeftAlone() async throws {
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.date = .constant(Date(timeIntervalSince1970: 1_780_000_000))
      $0.pageFetcher = PageFetcher { _ in Issue.record("must not fetch when hours present"); return nil }
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let ideaID = try await database.write { db -> Idea.ID in
        let id = try self.seedIdea(in: db)
        try Idea.setOpeningHours(
          ideaID: id, hours: "Mo-Fr 10-18", provenance: .manual,
          verifiedAt: Date(timeIntervalSince1970: 1), in: db
        )
        return id
      }
      let outcome = await FieldSupplement().supplementHours(ideaID: ideaID)
      #expect(outcome == .alreadyPresent)
    }
  }

  @Test("No rung can fill → notFound (the app then offers the HITL browser)")
  func notFoundFallsThrough() async throws {
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.date = .constant(Date(timeIntervalSince1970: 1_780_000_000))
      $0.pageFetcher = PageFetcher { _ in "<html><body>No hours here.</body></html>" }
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let ideaID = try await database.write { db in try self.seedIdea(in: db) }
      let outcome = await FieldSupplement().supplementHours(ideaID: ideaID)
      #expect(outcome == .notFound)
      let idea = try #require(try await database.read { db in try Idea.find(ideaID).fetchOne(db) })
      #expect(idea.openingHours == nil)
    }
  }

  @Test("Rung 3 HITL write-back stamps hours unverified")
  func browsedHoursAreUnverified() async throws {
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.date = .constant(Date(timeIntervalSince1970: 1_780_000_000))
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let ideaID = try await database.write { db in try self.seedIdea(in: db) }
      let filled = await FieldSupplement().applyBrowsedHours(
        html: Self.siteHTML, sourceURL: nil, ideaID: ideaID
      )
      #expect(filled)
      let idea = try #require(try await database.read { db in try Idea.find(ideaID).fetchOne(db) })
      #expect(idea.openingHours == "Tu-Sa 17:00-23:00")
      #expect(idea.hoursProvenance == .unverified)
    }
  }

  @Test("setOpeningHours clears the field and provenance on blank input")
  func clearingHours() async throws {
    try await withDependencies {
      try $0.bootstrapDatabase()
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let ideaID = try await database.write { db -> Idea.ID in
        let id = try self.seedIdea(in: db)
        try Idea.setOpeningHours(
          ideaID: id, hours: "Mo-Fr 10-18", provenance: .manual, verifiedAt: Date(), in: db
        )
        try Idea.setOpeningHours(
          ideaID: id, hours: "   ", provenance: .manual, verifiedAt: Date(), in: db
        )
        return id
      }
      let idea = try #require(try await database.read { db in try Idea.find(ideaID).fetchOne(db) })
      #expect(idea.openingHours == nil)
      #expect(idea.hoursProvenance == nil)
      #expect(idea.hoursVerifiedAt == nil)
    }
  }
}
