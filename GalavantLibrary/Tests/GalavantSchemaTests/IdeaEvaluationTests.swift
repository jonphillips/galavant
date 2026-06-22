import Foundation
import GalavantSchema
import Testing

/// `IdeaEvaluation` is the source-judgment sibling record (ADR-0015). These tests
/// exercise its pure read-model helpers — no database — mirroring `TripStayTests`.
@Suite struct IdeaEvaluationTests {
  let partyID = UUID()

  func idea(_ id: UUID = UUID(), name: String = "Place") -> Idea {
    Idea(id: id, name: name)
  }

  func evaluation(
    id: UUID = UUID(),
    ideaID: UUID,
    source: String = "Michelin Guide",
    kind: EvaluationKind = .stars,
    nativeValueText: String = "3 stars",
    nativeDisplay: String = "★★★",
    nativeValueNumber: Double? = 3,
    nativeValueMax: Double? = 3,
    confidence: EvaluationConfidence = .official,
    staleness: EvaluationStaleness = .current,
    recordedAt: Date = Date()
  ) -> IdeaEvaluation {
    IdeaEvaluation(
      id: id,
      travelPartyID: partyID,
      ideaID: ideaID,
      sourceName: source,
      kind: kind,
      nativeValueText: nativeValueText,
      nativeValueNumber: nativeValueNumber,
      nativeValueMax: nativeValueMax,
      nativeDisplay: nativeDisplay,
      recordedAt: recordedAt,
      confidence: confidence,
      staleness: staleness
    )
  }

  // MARK: - evaluations(forIdea:from:knownIdeaIDs:)

  @Test func basicFilterByIdeaID() {
    let (a, b) = (UUID(), UUID())
    let evals = [
      evaluation(ideaID: a, source: "Michelin Guide"),
      evaluation(ideaID: b, source: "Andrew Harper"),
      evaluation(ideaID: a, source: "Forbes"),
    ]
    let known = Set([a, b])
    let result = IdeaEvaluation.evaluations(forIdea: a, from: evals, knownIdeaIDs: known)
    #expect(result.count == 2)
    #expect(result.map(\.sourceName).contains("Michelin Guide"))
    #expect(result.map(\.sourceName).contains("Forbes"))
  }

  @Test func orphanEvaluationDropsWhenIdeaGone() {
    let present = UUID()
    let gone = UUID()
    let evals = [
      evaluation(ideaID: present, source: "Michelin Guide"),
      evaluation(ideaID: gone, source: "Andrew Harper"),
    ]
    // Only `present` in the known set — gone's evaluation drops.
    let known: Set<UUID> = [present]
    let presentResult = IdeaEvaluation.evaluations(forIdea: present, from: evals, knownIdeaIDs: known)
    let goneResult = IdeaEvaluation.evaluations(forIdea: gone, from: evals, knownIdeaIDs: known)
    #expect(presentResult.count == 1)
    #expect(goneResult.isEmpty)
  }

  @Test func multipleEvaluationsPerIdea() {
    let ideaID = UUID()
    let evals = [
      evaluation(ideaID: ideaID, source: "Michelin Guide"),
      evaluation(ideaID: ideaID, source: "Andrew Harper",
                 kind: .numericScore, nativeValueText: "96",
                 nativeDisplay: "96/100", nativeValueNumber: 96, nativeValueMax: 100),
      evaluation(ideaID: ideaID, source: "World's 50 Best",
                 kind: .rank, nativeValueText: "No. 12",
                 nativeDisplay: "No. 12", nativeValueNumber: 12, nativeValueMax: nil),
    ]
    let known: Set<UUID> = [ideaID]
    let result = IdeaEvaluation.evaluations(forIdea: ideaID, from: evals, knownIdeaIDs: known)
    #expect(result.count == 3)
  }

  @Test func resultsOrderedMostRecentFirst() {
    let ideaID = UUID()
    let now = Date()
    let older = now.addingTimeInterval(-3600)
    let newest = now.addingTimeInterval(60)
    let evals = [
      evaluation(ideaID: ideaID, source: "A", recordedAt: older),
      evaluation(ideaID: ideaID, source: "B", recordedAt: newest),
      evaluation(ideaID: ideaID, source: "C", recordedAt: now),
    ]
    let known: Set<UUID> = [ideaID]
    let result = IdeaEvaluation.evaluations(forIdea: ideaID, from: evals, knownIdeaIDs: known)
    #expect(result.map(\.sourceName) == ["B", "C", "A"])
  }

  @Test func emptyPoolReturnsEmpty() {
    let ideaID = UUID()
    let result = IdeaEvaluation.evaluations(
      forIdea: ideaID, from: [], knownIdeaIDs: [ideaID])
    #expect(result.isEmpty)
  }

  // MARK: - currentAndHistorical(forIdea:from:knownIdeaIDs:)

  @Test func currentVsHistoricalSplit() {
    let ideaID = UUID()
    let evals = [
      evaluation(ideaID: ideaID, source: "Michelin 2025", staleness: .current),
      evaluation(ideaID: ideaID, source: "Harper 2018", staleness: .historical),
      evaluation(ideaID: ideaID, source: "Forbes 2020", staleness: .stale),
      evaluation(ideaID: ideaID, source: "Zagat", staleness: .unknown),
    ]
    let known: Set<UUID> = [ideaID]
    let split = IdeaEvaluation.currentAndHistorical(
      forIdea: ideaID, from: evals, knownIdeaIDs: known)
    #expect(split.current.count == 1)
    #expect(split.current[0].sourceName == "Michelin 2025")
    // historical bucket: everything not `.current`
    #expect(split.historical.count == 3)
    #expect(split.historical.map(\.sourceName).contains("Harper 2018"))
  }

  @Test func currentAndHistoricalAlsoDropsOrphans() {
    let present = UUID()
    let gone = UUID()
    let evals = [
      evaluation(ideaID: present, source: "Michelin", staleness: .current),
      evaluation(ideaID: gone, source: "Harper", staleness: .current),
    ]
    let known: Set<UUID> = [present]
    let split = IdeaEvaluation.currentAndHistorical(
      forIdea: gone, from: evals, knownIdeaIDs: known)
    #expect(split.current.isEmpty)
    #expect(split.historical.isEmpty)
  }

  // MARK: - Enum raw-value stability

  @Test func evaluationKindRawValues() {
    #expect(EvaluationKind.stars.rawValue == "stars")
    #expect(EvaluationKind.numericScore.rawValue == "numericScore")
    #expect(EvaluationKind.rank.rawValue == "rank")
    #expect(EvaluationKind.personal.rawValue == "personal")
  }

  @Test func confidenceRawValues() {
    #expect(EvaluationConfidence.official.rawValue == "official")
    #expect(EvaluationConfidence.unverified.rawValue == "unverified")
  }

  @Test func stalenessRawValues() {
    #expect(EvaluationStaleness.current.rawValue == "current")
    #expect(EvaluationStaleness.historical.rawValue == "historical")
    #expect(EvaluationStaleness.stale.rawValue == "stale")
    #expect(EvaluationStaleness.unknown.rawValue == "unknown")
  }
}
