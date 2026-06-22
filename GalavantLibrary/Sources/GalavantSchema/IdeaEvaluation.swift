import Foundation
import SQLiteData

/// How a source expresses its judgment — the vocabulary it uses. String raw values
/// are stable identifiers; never change a case after it ships (ADR-0015).
public enum EvaluationKind: String, QueryBindable, CaseIterable, Sendable {
  /// A tiered accolade (Michelin ★★★, Forbes Five-Star). Not a percentage.
  case stars
  /// A bounded numeric score (Andrew Harper 96/100). May have a max.
  case numericScore
  /// A list position (World's 50 Best No. 12).
  case rank
  /// An award or certification (Relais & Châteaux membership).
  case badge
  /// An editorial endorsement without a score (Michelin Recommended).
  case recommendation
  /// An appearance in a guide without an explicit judgment.
  case mention
  /// A personal annotation from a planner (Anchor, Dream, Skip).
  case personal
  /// A free-text note with no structured value.
  case text
}

/// How reliable this evaluation is at the time of capture (ADR-0015).
/// String raw values are stable; never renumber or rename a shipped case.
public enum EvaluationConfidence: String, QueryBindable, CaseIterable, Sendable {
  /// Sourced directly from the guide's own page or API.
  case official
  /// Typed in manually by a planner.
  case manual
  /// Scraped or imported from a third-party source.
  case imported
  /// Inferred by the model layer with stated uncertainty.
  case inferred
  /// Captured but not yet verified against the original source.
  case unverified

  public var label: String {
    switch self {
    case .official: "Official"
    case .manual: "Manual"
    case .imported: "Imported"
    case .inferred: "Inferred"
    case .unverified: "Unverified"
    }
  }
}

/// Whether the evaluation still reflects the source's current position (ADR-0015).
/// String raw values are stable; never renumber or rename a shipped case.
public enum EvaluationStaleness: String, QueryBindable, CaseIterable, Sendable {
  /// Reflects the source's current edition or most recent publication.
  case current
  /// Came from a past edition; the source may have re-rated since.
  case historical
  /// Known to be out of date (e.g. a restaurant closed, guide re-rated).
  case stale
  /// Freshness is unverifiable.
  case unknown

  public var label: String {
    switch self {
    case .current: "Current"
    case .historical: "Historical"
    case .stale: "Stale"
    case .unknown: "Unverified"
    }
  }
}

/// A source's judgment about a pool idea — native-faithful, one table (ADR-0015).
///
/// **Single real FK** to `TravelParty` (evaluation rides the party tree, cascade-
/// deletes with it). `ideaID` is a loose, optional UUID — no SQL FK — reconciled on
/// read: evaluations whose idea no longer exists are dropped. Born, not pulled
/// (ADR-0004): created directly by capture (M6c) or manual entry, no pull lifecycle.
/// Many evaluations per idea is the common case; no uniqueness constraint per source.
///
/// The `nativeValueText`/`nativeValueNumber`/`nativeDisplay` triad preserves source
/// fidelity: `nativeDisplay` is what the UI shows (`★★★`, `96/100`, `No. 12`);
/// `nativeValueNumber` enables within-source sort/filter only — never cross-source
/// arithmetic (a 2-star is not "66% of" a 3-star; ADR-0015 §1).
@Table
public struct IdeaEvaluation: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var travelPartyID: TravelParty.ID
  public var ideaID: Idea.ID

  // MARK: — source-native judgment
  public var sourceName: String
  public var kind: EvaluationKind
  public var nativeValueText: String
  public var nativeValueNumber: Double?
  public var nativeValueMax: Double?
  public var nativeDisplay: String

  // MARK: — provenance & freshness
  public var evaluationDate: Date?
  public var guideYear: Int?
  public var recordedAt: Date
  public var lastVerifiedAt: Date?
  public var confidence: EvaluationConfidence
  public var staleness: EvaluationStaleness
  public var sourceURL: String?
  public var summary: String?

  public init(
    id: UUID,
    travelPartyID: TravelParty.ID,
    ideaID: Idea.ID,
    sourceName: String,
    kind: EvaluationKind,
    nativeValueText: String,
    nativeValueNumber: Double? = nil,
    nativeValueMax: Double? = nil,
    nativeDisplay: String,
    evaluationDate: Date? = nil,
    guideYear: Int? = nil,
    recordedAt: Date,
    lastVerifiedAt: Date? = nil,
    confidence: EvaluationConfidence,
    staleness: EvaluationStaleness,
    sourceURL: String? = nil,
    summary: String? = nil
  ) {
    self.id = id
    self.travelPartyID = travelPartyID
    self.ideaID = ideaID
    self.sourceName = sourceName
    self.kind = kind
    self.nativeValueText = nativeValueText
    self.nativeValueNumber = nativeValueNumber
    self.nativeValueMax = nativeValueMax
    self.nativeDisplay = nativeDisplay
    self.evaluationDate = evaluationDate
    self.guideYear = guideYear
    self.recordedAt = recordedAt
    self.lastVerifiedAt = lastVerifiedAt
    self.confidence = confidence
    self.staleness = staleness
    self.sourceURL = sourceURL
    self.summary = summary
  }
}
