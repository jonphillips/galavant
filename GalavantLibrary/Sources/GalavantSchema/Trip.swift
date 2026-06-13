import Foundation
import SQLiteData

/// A trip in the planning pipeline. Its commitment level is the `Certainty`
/// pipeline (`someday → targeted → dated`), stored as flat columns so the list
/// can group and sort by it; read/write the domain enum via `certainty`
/// (Certainty.swift). `lengthInDays` is the stable duration fact — nothing
/// downstream keys off the calendar date (docs/trip-time-model.md). Single real
/// FK to TravelParty so it rides the share (ADR-0007).
@Table
public struct Trip: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name = ""
  public var notes = ""
  public var certaintyStage: CertaintyStage = .someday
  /// Order within the `someday` backlog (lower = higher up). Meaningful only
  /// while `certaintyStage == .someday`; reset to 0 in the other stages.
  public var somedayRank = 0
  public var targetYear: Int?
  public var targetQuarter: Quarter?
  public var startDate: Date?
  public var lengthInDays = 7
  public var travelPartyID: TravelParty.ID?

  public init(
    id: UUID,
    name: String = "",
    notes: String = "",
    certaintyStage: CertaintyStage = .someday,
    somedayRank: Int = 0,
    targetYear: Int? = nil,
    targetQuarter: Quarter? = nil,
    startDate: Date? = nil,
    lengthInDays: Int = 7,
    travelPartyID: TravelParty.ID? = nil
  ) {
    self.id = id
    self.name = name
    self.notes = notes
    self.certaintyStage = certaintyStage
    self.somedayRank = somedayRank
    self.targetYear = targetYear
    self.targetQuarter = targetQuarter
    self.startDate = startDate
    self.lengthInDays = lengthInDays
    self.travelPartyID = travelPartyID
  }
}
