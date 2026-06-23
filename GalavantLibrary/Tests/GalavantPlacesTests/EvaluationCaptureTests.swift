import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantCapture
import GalavantSchema
import SQLiteData
import Testing

@testable import GalavantPlaces

/// Source-aware capture (ADR-0016 §1): a shared ratings page lands the idea **and**
/// faithful sibling `IdeaEvaluation`s, in one transaction; the LLM extract-only
/// fallback fires only when deterministic recognizers find nothing; the bridge
/// stamps confidence/staleness/kind.
@MainActor
@Suite struct EvaluationCaptureTests {
  private static let michelinHTML = """
    <html><head>
    <script type="application/ld+json">{
      "@context": "https://schema.org",
      "@type": "Restaurant",
      "name": "Geranium",
      "award": "Three MICHELIN Stars",
      "geo": { "@type": "GeoCoordinates", "latitude": 55.703, "longitude": 12.572 }
    }</script>
    </head><body><p>Three MICHELIN Stars · MICHELIN Guide 2026</p></body></html>
    """

  @Test("Sharing a Michelin page lands the idea and a faithful ★★★ evaluation")
  func michelinCaptureWritesEvaluation() async throws {
    let stamp = Date(timeIntervalSince1970: 1_780_000_000)  // 2026
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.placeMatcher = .testValue
      $0.date = .constant(stamp)
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let model = CaptureModel(
        html: Self.michelinHTML,
        sourceURL: URL(string: "https://guide.michelin.com/dk/en/restaurant/geranium")
      )
      await model.prepare()
      // The recognizer surfaced one rating, marked official, included by default.
      #expect(model.detectedEvaluations.count == 1)
      #expect(model.detectedEvaluations.first?.confidence == .official)
      #expect(model.detectedEvaluations.first?.included == true)

      await model.save()
      #expect(model.phase == .saved)

      let evaluations = try await database.read { db in try IdeaEvaluation.all.fetchAll(db) }
      let eval = try #require(evaluations.first)
      #expect(evaluations.count == 1)
      #expect(eval.sourceName == "Michelin Guide")
      #expect(eval.kind == .stars)
      #expect(eval.nativeDisplay == "★★★")
      #expect(eval.nativeValueNumber == 3)
      #expect(eval.confidence == .official)
      #expect(eval.staleness == .current)  // 2026 guide, captured 2026
      #expect(eval.guideYear == 2026)
      // It rides the same idea + travel party as the captured idea.
      let idea = try #require(try await database.read { db in try Idea.all.fetchAll(db) }.first)
      #expect(eval.ideaID == idea.id)
      #expect(eval.travelPartyID == idea.travelPartyID)
    }
  }

  @Test("An excluded evaluation is not written")
  func excludedEvaluationIsDropped() async throws {
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.placeMatcher = .testValue
      $0.date = .constant(Date(timeIntervalSince1970: 1_780_000_000))
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let model = CaptureModel(
        html: Self.michelinHTML, sourceURL: URL(string: "https://guide.michelin.com/x")
      )
      await model.prepare()
      model.detectedEvaluations[0].included = false
      await model.save()
      let count = try await database.read { db in try IdeaEvaluation.all.fetchCount(db) }
      #expect(count == 0)
      // The idea itself still saved.
      let ideaCount = try await database.read { db in try Idea.all.fetchCount(db) }
      #expect(ideaCount == 1)
    }
  }

  @Test("The LLM extract-only fallback fires only when no recognizer matched")
  func llmFallbackFillsWhenDeterministicEmpty() async throws {
    let plainHTML = """
      <html><head><title>A Place</title></head>
      <body><h1>A Place</h1><p>A lovely spot for dinner.</p></body></html>
      """
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.placeMatcher = .testValue
      $0.date = .constant(Date(timeIntervalSince1970: 1_780_000_000))
      $0.evaluationExtractor = EvaluationExtractor { _ in
        [ParsedEvaluation(sourceName: "Critic", kind: .recommendation, valueText: "Loved it", display: "Loved it")]
      }
    } operation: {
      @Dependency(\.defaultDatabase) var database
      let model = CaptureModel(html: plainHTML, sourceURL: URL(string: "https://aplace.example/"))
      await model.prepare()
      #expect(model.detectedEvaluations.count == 1)
      #expect(model.detectedEvaluations.first?.confidence == .inferred)  // LLM path

      await model.save()
      let eval = try #require(try await database.read { db in try IdeaEvaluation.all.fetchAll(db) }.first)
      #expect(eval.sourceName == "Critic")
      #expect(eval.confidence == .inferred)
    }
  }

  @Test("A recognized page never consults the LLM fallback")
  func recognizedPageSkipsLLM() async throws {
    try await withDependencies {
      try $0.bootstrapDatabase()
      $0.uuid = .incrementing
      $0.placeMatcher = .testValue
      $0.date = .constant(Date(timeIntervalSince1970: 1_780_000_000))
      $0.evaluationExtractor = EvaluationExtractor { _ in
        Issue.record("LLM fallback must not run when a recognizer matched")
        return []
      }
    } operation: {
      let model = CaptureModel(
        html: Self.michelinHTML, sourceURL: URL(string: "https://guide.michelin.com/x")
      )
      await model.prepare()
      #expect(model.detectedEvaluations.first?.confidence == .official)
    }
  }

  // MARK: - Pure mapping

  @Test("Staleness derives from the guide year relative to now")
  func stalenessFromGuideYear() {
    let now2026 = Date(timeIntervalSince1970: 1_780_000_000)
    #expect(IdeaEvaluation.staleness(guideYear: 2026, evaluationDate: nil, asOf: now2026) == .current)
    #expect(IdeaEvaluation.staleness(guideYear: 2025, evaluationDate: nil, asOf: now2026) == .current)
    #expect(IdeaEvaluation.staleness(guideYear: 2018, evaluationDate: nil, asOf: now2026) == .historical)
    #expect(IdeaEvaluation.staleness(guideYear: nil, evaluationDate: nil, asOf: now2026) == .current)
  }

  @Test("Parser kinds map onto schema kinds")
  func kindMapping() {
    #expect(IdeaEvaluation.kind(from: .stars) == .stars)
    #expect(IdeaEvaluation.kind(from: .numericScore) == .numericScore)
    #expect(IdeaEvaluation.kind(from: .rank) == .rank)
    #expect(IdeaEvaluation.kind(from: .badge) == .badge)
    #expect(IdeaEvaluation.kind(from: .recommendation) == .recommendation)
    #expect(IdeaEvaluation.kind(from: .mention) == .mention)
    #expect(IdeaEvaluation.kind(from: .text) == .text)
  }

  // MARK: - LLM JSON parsing

  @Test("The extractor parses a model JSON array, dropping malformed elements")
  func extractorParsesJSON() {
    let text = """
      Here you go:
      [
        {"sourceName":"Gambero Rosso","kind":"numericScore","valueText":"Tre Forchette","display":"Tre Forchette","valueNumber":3,"valueMax":3},
        {"kind":"stars"},
        {"sourceName":"Critic","kind":"unknownkind","valueText":"x","display":"x"}
      ]
      """
    let parsed = EvaluationExtractor.parse(text, sourceURL: "https://x.example")
    #expect(parsed.count == 1)
    #expect(parsed.first?.sourceName == "Gambero Rosso")
    #expect(parsed.first?.kind == .numericScore)
    #expect(parsed.first?.valueNumber == 3)
    #expect(parsed.first?.sourceURL == "https://x.example")
  }

  @Test("The extractor returns nothing for a non-array response")
  func extractorToleratesGarbage() {
    #expect(EvaluationExtractor.parse("I could not find any ratings.", sourceURL: nil).isEmpty)
  }
}
