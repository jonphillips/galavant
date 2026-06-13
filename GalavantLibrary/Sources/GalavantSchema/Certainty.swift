import Foundation
import IssueReporting

/// The trip dating pipeline as a single domain value (STYLE §3): a trip is
/// either a vague `someday` (ranked in a backlog), `targeted` at a year and
/// optional quarter, or `dated` with a real start. `Trip` stores this as flat
/// columns for queryability; this enum is the in-memory representation and the
/// form's source of truth. Conversions are total in both directions.
public enum Certainty: Equatable, Sendable {
  case someday(rank: Int)
  case targeted(year: Int, quarter: Quarter?)
  case dated(start: Date)

  public var stage: CertaintyStage {
    switch self {
    case .someday: .someday
    case .targeted: .targeted
    case .dated: .dated
    }
  }

  /// Backlog position, only non-default for `someday`.
  public var somedayRank: Int {
    if case let .someday(rank) = self { rank } else { 0 }
  }

  public var targetYear: Int? {
    if case let .targeted(year, _) = self { year } else { nil }
  }

  public var targetQuarter: Quarter? {
    if case let .targeted(_, quarter) = self { quarter } else { nil }
  }

  public var startDate: Date? {
    if case let .dated(start) = self { start } else { nil }
  }

  /// Rebuild from the stored columns. Total: a stage whose payload column is
  /// missing (a should-never-happen write) reports an issue and falls back to a
  /// `someday` so the UI never has to handle a partial trip.
  public init(
    stage: CertaintyStage,
    somedayRank: Int,
    targetYear: Int?,
    targetQuarter: Quarter?,
    startDate: Date?
  ) {
    switch stage {
    case .someday:
      self = .someday(rank: somedayRank)
    case .targeted:
      guard let targetYear else {
        reportIssue("Targeted trip missing targetYear; treating as someday")
        self = .someday(rank: somedayRank)
        return
      }
      self = .targeted(year: targetYear, quarter: targetQuarter)
    case .dated:
      guard let startDate else {
        reportIssue("Dated trip missing startDate; treating as someday")
        self = .someday(rank: somedayRank)
        return
      }
      self = .dated(start: startDate)
    }
  }
}

extension Trip {
  /// The trip's commitment level as a domain value, rebuilt from its columns.
  public var certainty: Certainty {
    Certainty(
      stage: certaintyStage,
      somedayRank: somedayRank,
      targetYear: targetYear,
      targetQuarter: targetQuarter,
      startDate: startDate
    )
  }

  /// Write a `Certainty` back into the flat columns, clearing the columns the
  /// chosen stage doesn't use so storage never carries stale payloads.
  public mutating func apply(_ certainty: Certainty) {
    certaintyStage = certainty.stage
    somedayRank = certainty.somedayRank
    targetYear = certainty.targetYear
    targetQuarter = certainty.targetQuarter
    startDate = certainty.startDate
  }
}

extension Trip.Draft {
  /// See `Trip.apply(_:)` — the same mapping for the form's draft.
  public mutating func apply(_ certainty: Certainty) {
    certaintyStage = certainty.stage
    somedayRank = certainty.somedayRank
    targetYear = certainty.targetYear
    targetQuarter = certainty.targetQuarter
    startDate = certainty.startDate
  }
}
