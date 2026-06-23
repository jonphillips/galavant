import Foundation
import SQLiteData

/// How a *factual* field on an idea (opening hours first; later a menu URL, a price
/// band) was sourced — the facts analogue of `EvaluationStaleness`/`Confidence`
/// (ADR-0016 §2). Facts live on `Idea`; judgments live on `IdeaEvaluation`. Stamped
/// on whatever the field-supplement ladder touches so a stale or unverified fact
/// never masquerades as authoritative. String raw values are stable; never renumber
/// or rename a shipped case (CloudKit schema rule).
public enum FactProvenance: String, QueryBindable, CaseIterable, Sendable {
  /// From an authoritative, current source — the place's own site or MapKit.
  case official
  /// Grabbed via the human-in-the-loop browser; not yet confirmed against the source.
  case unverified
  /// Entered or edited by a planner.
  case manual

  public var label: String {
    switch self {
    case .official: "Verified"
    case .unverified: "Unverified"
    case .manual: "Edited"
    }
  }
}
