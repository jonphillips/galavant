import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantAI
import GalavantSchema
import SQLiteData
import Testing

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct RecommendationHandoffTests {
  @Dependency(\.defaultDatabase) var database

  @Test func scopeKeysRoundTripThroughTheirOpaqueEncoding() throws {
    let stayID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let transferID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    let scopes: [RecommendationHandoffScope] = [.day(3), .stay(stayID), .transfer(transferID), .trip]

    for scope in scopes {
      #expect(try RecommendationHandoffScope(sourceType: scope.sourceType, scopeKey: scope.scopeKey) == scope)
    }
  }

  @Test func decodesCandidateFixtureWithoutLosingAdvisoryFields() throws {
    let fixture = try #require(
      Bundle.module.url(forResource: "recommendation-candidates", withExtension: "json")
    )
    let candidates = try TripCandidate.decodeReturn(String(contentsOf: fixture, encoding: .utf8))
    let candidate = try #require(candidates.only)

    #expect(candidate.name == "Lumiere Brasserie")
    #expect(candidate.locality == "Bolzano")
    #expect(candidate.searchHint == "Lumiere Brasserie Bolzano")
    #expect(candidate.rationale == "A relaxed dinner after the museum.\n\nIt keeps the evening walkable from the old town.")
    #expect(candidate.priority == 4)
    #expect(candidate.dayRef == "3")
    #expect(candidate.placementAfter == "Forestis")
  }

  @Test func malformedReturnFailsLoudly() {
    #expect(throws: TripCandidateDecodeError.malformedJSON) {
      try TripCandidate.decodeReturn("[{\"name\": }]")
    }
  }

  @Test func emptyReturnFailsLoudlyAtTheDecodeBoundary() {
    #expect(throws: TripCandidateDecodeError.emptyCandidates) {
      try TripCandidate.decodeReturn("[]")
    }
  }

  @Test func ignoresAStrayOpeningBracketBeforeTheCandidateArray() throws {
    let candidates = try TripCandidate.decodeReturn(
      "The output has a stray [ in this sentence.\n[{\"name\": \"Plose\"}]"
    )

    #expect(candidates.only?.name == "Plose")
  }

  @Test func partialFieldsReachReviewWithoutBlockingIngestion() throws {
    let candidates = try TripCandidate.decodeReturn("[{\"search_hint\": \"Cable car near Brixen\"}]")
    let candidate = try #require(candidates.only)

    #expect(candidate.name == nil)
    #expect(candidate.searchHint == "Cable car near Brixen")
    #expect(candidate.suggestedTitle == "Cable car near Brixen")
  }

  @Test func candidateCommitsAsAConsideringFreeformTripIdea() async throws {
    let committed = try await database.write { db -> TripIdea in
      let trip = try Trip.create(name: "South Tyrol", in: db)
      return try TripIdea.commit(
        candidate: TripCandidate(
          name: "Lumiere Brasserie",
          locality: "Bolzano",
          why: "A relaxed dinner after the museum.",
          fit: "Walkable from the old town.",
          priority: 4
        ),
        into: trip.id,
        in: db
      )
    }

    #expect(committed.ideaID == nil)
    #expect(committed.inlineTitle == "Lumiere Brasserie")
    #expect(committed.inlineNote == "A relaxed dinner after the museum.\n\nWalkable from the old town.")
    #expect(committed.status == .considering)
    #expect(committed.shortlistRank == 4)
  }
}

private extension Collection {
  var only: Element? { count == 1 ? first : nil }
}
