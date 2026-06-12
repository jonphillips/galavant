import Foundation
import SQLiteData

/// One planner's interest in one idea (their level + an optional personal note).
/// Single real foreign key to Idea so it rides the travel party share; `plannerID`
/// is a loose UUID, not a SQL FK (ADR-0007's single-FK sharing rule).
@Table
public struct IdeaInterest: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var ideaID: Idea.ID
  public var plannerID: Planner.ID
  public var level: Interest?
  public var note = ""

  public init(
    id: UUID,
    ideaID: Idea.ID,
    plannerID: Planner.ID,
    level: Interest? = nil,
    note: String = ""
  ) {
    self.id = id
    self.ideaID = ideaID
    self.plannerID = plannerID
    self.level = level
    self.note = note
  }
}
