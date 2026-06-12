import Foundation
import SQLiteData

/// A person who plans. Not an account — identity is the iCloud account graph
/// (ADR-0001); a Planner is just a synced row that authored content references
/// (ratings, notes, captured ideas). See ADR-0007.
@Table
public struct Planner: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var displayName = ""
  public var travelPartyID: TravelParty.ID?

  public init(id: UUID, displayName: String = "", travelPartyID: TravelParty.ID? = nil) {
    self.id = id
    self.displayName = displayName
    self.travelPartyID = travelPartyID
  }
}
