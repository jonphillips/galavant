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
  ///
  /// Idempotent on the source-native triad (source, kind, value): a detection the
  /// idea already carries is skipped, so re-sharing the same place doesn't double its
  /// ratings (ADR-0019 §3). The same guard de-dups repeats *within* a single batch.
  public static func record(
    _ detections: [DetectedEvaluation],
    ideaID: Idea.ID,
    travelPartyID: TravelParty.ID,
    asOf now: Date,
    in db: Database
  ) throws {
    let existing = try IdeaEvaluation.where { $0.ideaID.eq(ideaID) }.fetchAll(db)
    var seen = Set(
      existing.map {
        EvaluationKey(source: $0.sourceName, kind: $0.kind, value: $0.nativeValueText)
      }
    )
    for detected in detections {
      let key = EvaluationKey(
        source: detected.parsed.sourceName,
        kind: kind(from: detected.parsed.kind),
        value: detected.parsed.valueText
      )
      guard seen.insert(key).inserted else { continue }
      try record(
        detected.parsed, ideaID: ideaID, travelPartyID: travelPartyID,
        confidence: detected.confidence, asOf: now, in: db
      )
    }
  }

  /// The identity of a judgment for de-dup (ADR-0019 §3): two evaluations are "the
  /// same" when their source, kind, and native value agree — the same accolade,
  /// however many times the page is captured.
  private struct EvaluationKey: Hashable {
    var source: String
    var kind: EvaluationKind
    var value: String
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
