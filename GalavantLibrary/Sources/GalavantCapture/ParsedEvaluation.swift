import Foundation

/// How a source on a page expressed its judgment — the domain-free cousin of the
/// schema's `EvaluationKind`. The parser speaks this vocabulary; the domain bridge
/// (`GalavantPlaces`) maps it onto `IdeaEvaluation` (ADR-0016 §1). No Galavant types
/// here, so the engine stays portable (the portfolio-extraction seam).
public enum ParsedEvaluationKind: String, Equatable, Sendable, CaseIterable {
  /// A tiered accolade (Michelin ★★★, Forbes Five-Star). Not a percentage.
  case stars
  /// A bounded numeric score (Andrew Harper 96/100). May have a max.
  case numericScore
  /// A list position (World's 50 Best No. 12).
  case rank
  /// An award or certification (Bib Gourmand, Green Star, Relais & Châteaux).
  case badge
  /// An editorial endorsement without a score (Michelin Recommended / Plate).
  case recommendation
  /// An appearance in a guide without an explicit judgment.
  case mention
  /// A free-text note with no structured value.
  case text
}

/// A source-attributed *native* judgment scraped from a page — kept exactly as the
/// source expressed it, never normalized (ADR-0015's native-fidelity rule, applied
/// at the parser). Domain-free, like the rest of `ParsedPage`: it carries no
/// `Idea`/`IdeaEvaluation`/MapKit, so `GalavantCapture` never sees the schema.
///
/// Recognizers (`EvaluationRecognizers`) produce these least→most structured;
/// deterministic recognizers always win, with the on-device LLM extract-only path
/// (`EvaluationExtractor`, in the bridge) firing only when none fire. The bridge
/// stamps the domain fields the parser can't know (`confidence`, `staleness`,
/// `recordedAt`, `ideaID`, `travelPartyID`).
public struct ParsedEvaluation: Equatable, Sendable {
  /// The judging source, as it names itself ("Michelin Guide", "Andrew Harper").
  public var sourceName: String
  public var kind: ParsedEvaluationKind
  /// The native value verbatim ("3 stars", "96", "No. 12", "Bib Gourmand").
  public var valueText: String
  /// The value as a number, when it has one — within-source sort/filter only,
  /// never cross-source arithmetic (a 2-star is not "66% of" a 3-star).
  public var valueNumber: Double?
  /// The value's scale, when bounded (3 for stars, 100 for a /100 score).
  public var valueMax: Double?
  /// What the UI shows ("★★★", "96/100", "No. 12") — the source's own presentation.
  public var display: String
  /// The guide edition year, when the page states one.
  public var guideYear: Int?
  /// When the source made the judgment, when the page dates it.
  public var evaluationDate: Date?
  /// The page the judgment came from.
  public var sourceURL: String?

  public init(
    sourceName: String,
    kind: ParsedEvaluationKind,
    valueText: String,
    valueNumber: Double? = nil,
    valueMax: Double? = nil,
    display: String,
    guideYear: Int? = nil,
    evaluationDate: Date? = nil,
    sourceURL: String? = nil
  ) {
    self.sourceName = sourceName
    self.kind = kind
    self.valueText = valueText
    self.valueNumber = valueNumber
    self.valueMax = valueMax
    self.display = display
    self.guideYear = guideYear
    self.evaluationDate = evaluationDate
    self.sourceURL = sourceURL
  }
}
