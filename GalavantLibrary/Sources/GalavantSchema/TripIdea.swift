import Foundation
import SQLiteData

/// One idea pulled onto one trip, carrying its lifecycle `status` (ADR-0004).
/// The single real foreign key is to `Trip` (so the join rides the trip and
/// cascade-deletes with it); `ideaID` is a loose UUID, not a SQL FK, per the
/// single-FK sharing rule (ADR-0007) — orphans (idea deleted from the pool) are
/// reconciled on read, as with IdeaInterest. `shortlistRank` orders the
/// shortlist (V1's RankLists reborn as an ordering, ADR-0004).
@Table
public struct TripIdea: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tripID: Trip.ID
  public var ideaID: Idea.ID
  public var status: TripIdeaStatus = .considering
  public var shortlistRank = 0

  public init(
    id: UUID,
    tripID: Trip.ID,
    ideaID: Idea.ID,
    status: TripIdeaStatus = .considering,
    shortlistRank: Int = 0
  ) {
    self.id = id
    self.tripID = tripID
    self.ideaID = ideaID
    self.status = status
    self.shortlistRank = shortlistRank
  }
}
