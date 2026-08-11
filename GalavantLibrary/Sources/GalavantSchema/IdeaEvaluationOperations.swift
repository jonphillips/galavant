import Foundation
import SQLiteData

extension IdeaEvaluation {
  // MARK: - Write ops (ADR-0015)

  /// Record a source's judgment about an idea. `recordedAt` stamps the moment of
  /// capture; `evaluationDate` is when the *source* made the judgment (e.g. a 2018
  /// Harper review). Returns the new evaluation's id.
  @discardableResult
  public static func create(
    travelPartyID: TravelParty.ID,
    ideaID: Idea.ID,
    sourceName: String,
    kind: EvaluationKind,
    nativeValueText: String,
    nativeDisplay: String,
    nativeValueNumber: Double? = nil,
    nativeValueMax: Double? = nil,
    evaluationDate: Date? = nil,
    guideYear: Int? = nil,
    confidence: EvaluationConfidence = .unverified,
    staleness: EvaluationStaleness = .unknown,
    sourceURL: String? = nil,
    summary: String? = nil,
    in db: Database
  ) throws -> IdeaEvaluation.ID {
    let id = UUID()
    try IdeaEvaluation.insert {
      IdeaEvaluation.Draft(
        IdeaEvaluation(
          id: id,
          travelPartyID: travelPartyID,
          ideaID: ideaID,
          sourceName: sourceName,
          kind: kind,
          nativeValueText: nativeValueText,
          nativeValueNumber: nativeValueNumber,
          nativeValueMax: nativeValueMax,
          nativeDisplay: nativeDisplay,
          evaluationDate: evaluationDate,
          guideYear: guideYear,
          recordedAt: Date(),
          confidence: confidence,
          staleness: staleness,
          sourceURL: sourceURL,
          summary: summary
        )
      )
    }
    .execute(db)
    return id
  }

  /// Revise a captured evaluation's mutable fields. `recordedAt` and identity
  /// columns (`id`, `travelPartyID`, `ideaID`) are immutable once created.
  /// No-op on a missing evaluation.
  public static func edit(
    evaluationID: IdeaEvaluation.ID,
    sourceName: String,
    kind: EvaluationKind,
    nativeValueText: String,
    nativeDisplay: String,
    nativeValueNumber: Double? = nil,
    nativeValueMax: Double? = nil,
    evaluationDate: Date? = nil,
    guideYear: Int? = nil,
    lastVerifiedAt: Date? = nil,
    confidence: EvaluationConfidence,
    staleness: EvaluationStaleness,
    sourceURL: String? = nil,
    summary: String? = nil,
    in db: Database
  ) throws {
    guard try IdeaEvaluation.find(evaluationID).fetchOne(db) != nil else { return }
    try IdeaEvaluation.find(evaluationID)
      .update {
        $0.sourceName = #bind(sourceName)
        $0.kind = #bind(kind)
        $0.nativeValueText = #bind(nativeValueText)
        $0.nativeValueNumber = #bind(nativeValueNumber)
        $0.nativeValueMax = #bind(nativeValueMax)
        $0.nativeDisplay = #bind(nativeDisplay)
        $0.evaluationDate = #bind(evaluationDate)
        $0.guideYear = #bind(guideYear)
        $0.lastVerifiedAt = #bind(lastVerifiedAt)
        $0.confidence = #bind(confidence)
        $0.staleness = #bind(staleness)
        $0.sourceURL = #bind(sourceURL)
        $0.summary = #bind(summary)
      }
      .execute(db)
  }

  /// Delete an evaluation from the pool.
  public static func remove(evaluationID: IdeaEvaluation.ID, in db: Database) throws {
    try IdeaEvaluation.find(evaluationID).delete().execute(db)
  }
}

extension IdeaEvaluation {
  // MARK: - Read-model helpers (pure, ADR-0015)

  /// Evaluations for an idea from a pre-fetched array, with orphan-drop: if the
  /// idea's id is not in `knownIdeaIDs` the evaluation is excluded (the idea was
  /// deleted). Results are ordered most-recently-recorded first.
  public static func evaluations(
    forIdea ideaID: Idea.ID,
    from all: [IdeaEvaluation],
    knownIdeaIDs: Set<Idea.ID>
  ) -> [IdeaEvaluation] {
    guard knownIdeaIDs.contains(ideaID) else { return [] }
    return all
      .filter { $0.ideaID == ideaID }
      .sorted { $0.recordedAt > $1.recordedAt }
  }

  /// Split evaluations for an idea into current (`.current` staleness) and
  /// everything else (historical / stale / unknown), most-recently-recorded first
  /// within each bucket. Reuses the orphan-drop reconciliation from
  /// `evaluations(forIdea:from:knownIdeaIDs:)`.
  public static func currentAndHistorical(
    forIdea ideaID: Idea.ID,
    from all: [IdeaEvaluation],
    knownIdeaIDs: Set<Idea.ID>
  ) -> (current: [IdeaEvaluation], historical: [IdeaEvaluation]) {
    let resolved = evaluations(forIdea: ideaID, from: all, knownIdeaIDs: knownIdeaIDs)
    return (
      current: resolved.filter { $0.staleness == .current },
      historical: resolved.filter { $0.staleness != .current }
    )
  }
}
