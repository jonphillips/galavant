import Foundation
import GalavantCapture
import GalavantSchema
import SQLiteData

/// A detected source judgment as the capture confirm sheet presents it: the native
/// `ParsedEvaluation`, the `confidence` the bridge will stamp (`.official` for a
/// deterministic recognizer, `.inferred` for the LLM fallback), and whether Jon has
/// it `included` in the save. Carries its own `id` so a `ForEach` can bind it.
public struct DetectedEvaluation: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var parsed: ParsedEvaluation
  public var confidence: EvaluationConfidence
  public var included: Bool

  public init(
    id: UUID, parsed: ParsedEvaluation, confidence: EvaluationConfidence, included: Bool = true
  ) {
    self.id = id
    self.parsed = parsed
    self.confidence = confidence
    self.included = included
  }

  /// The judging source, for display ("Michelin Guide").
  public var sourceName: String { parsed.sourceName }
  /// The native value, for display ("★★★", "96/100") — never normalized.
  public var nativeDisplay: String { parsed.display }
}

/// The domain bridge for source-aware capture (ADR-0016 §1): maps a domain-free
/// `ParsedEvaluation` onto an `IdeaEvaluation`, stamping the fields the parser can't
/// know — `confidence` (from how the value was detected), `staleness` (from the
/// guide year / evaluation date), `recordedAt`, and the owning `ideaID` /
/// `travelPartyID`. Exactly parallels `CapturedPlace.from(_:)` mapping `ParsedPage`
/// → `Idea`; the capture *engine* stays schema-free, the mapping lives here.
extension IdeaEvaluation {
  /// Persist a detected evaluation against an idea. `confidence` is the caller's:
  /// `.official` for a deterministic recognizer (a recognized source page),
  /// `.inferred` for the on-device LLM extract-only fallback (ADR-0016 §1). Staleness
  /// is derived from the guide year / evaluation date relative to `now`.
  @discardableResult
  public static func record(
    _ parsed: ParsedEvaluation,
    ideaID: Idea.ID,
    travelPartyID: TravelParty.ID,
    confidence: EvaluationConfidence,
    asOf now: Date,
    in db: Database
  ) throws -> IdeaEvaluation.ID {
    try create(
      travelPartyID: travelPartyID,
      ideaID: ideaID,
      sourceName: parsed.sourceName,
      kind: kind(from: parsed.kind),
      nativeValueText: parsed.valueText,
      nativeDisplay: parsed.display,
      nativeValueNumber: parsed.valueNumber,
      nativeValueMax: parsed.valueMax,
      evaluationDate: parsed.evaluationDate,
      guideYear: parsed.guideYear,
      confidence: confidence,
      staleness: staleness(guideYear: parsed.guideYear, evaluationDate: parsed.evaluationDate, asOf: now),
      sourceURL: parsed.sourceURL,
      in: db
    )
  }

  /// Persist a batch of confirmed detections against an idea, each stamped with its
  /// own confidence (ADR-0016 §1) — the capture write's one-liner over the sheet's
  /// kept rows.
  public static func record(
    _ detections: [DetectedEvaluation],
    ideaID: Idea.ID,
    travelPartyID: TravelParty.ID,
    asOf now: Date,
    in db: Database
  ) throws {
    for detected in detections {
      try record(
        detected.parsed, ideaID: ideaID, travelPartyID: travelPartyID,
        confidence: detected.confidence, asOf: now, in: db
      )
    }
  }

  /// Map the parser's vocabulary onto the schema's. The parser never emits
  /// `.personal` (a planner annotation, not a scraped fact), so an exact rawValue
  /// match suffices; anything unexpected degrades to `.text`.
  public static func kind(from parsed: ParsedEvaluationKind) -> EvaluationKind {
    EvaluationKind(rawValue: parsed.rawValue) ?? .text
  }

  /// A captured judgment is `current` unless it carries a date showing it's from a
  /// past edition: a guide year older than last year, or an evaluation date more
  /// than ~18 months before `now`. Travel guides re-rate annually, so the prior
  /// year still counts as current. Absent any date → `current` (the page is live).
  public static func staleness(
    guideYear: Int?,
    evaluationDate: Date?,
    asOf now: Date
  ) -> EvaluationStaleness {
    let currentYear = Calendar.current.component(.year, from: now)
    if let guideYear, guideYear < currentYear - 1 { return .historical }
    if let evaluationDate, now.timeIntervalSince(evaluationDate) > 18 * 30 * 24 * 60 * 60 {
      return .historical
    }
    return .current
  }
}
