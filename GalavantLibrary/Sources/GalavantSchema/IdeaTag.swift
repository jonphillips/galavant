import Foundation
import SQLiteData

/// Join between an idea and a tag. Single real FK to Idea so it rides the
/// travel-party share; `tagID` is a loose UUID (ADR-0007's single-FK rule).
@Table
public struct IdeaTag: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var ideaID: Idea.ID
  public var tagID: Tag.ID

  public init(id: UUID, ideaID: Idea.ID, tagID: Tag.ID) {
    self.id = id
    self.ideaID = ideaID
    self.tagID = tagID
  }
}

extension IdeaTag {
  public static func add(tagID: Tag.ID, to ideaID: Idea.ID, in db: Database) throws {
    let matching = try IdeaTag
      .where { $0.ideaID.eq(ideaID) && $0.tagID.eq(tagID) }
      .fetchAll(db)
    let converged = matching.convergingByKey { [$0.ideaID, $0.tagID] }
    for loser in converged.losers {
      try IdeaTag.find(loser.id).delete().execute(db)
    }
    guard converged.survivors.isEmpty else { return }
    try IdeaTag.insert {
      IdeaTag.Draft(IdeaTag(id: UUID(), ideaID: ideaID, tagID: tagID))
    }
    .execute(db)
  }

  public static func remove(tagID: Tag.ID, from ideaID: Idea.ID, in db: Database) throws {
    try IdeaTag.where { $0.ideaID.eq(ideaID) && $0.tagID.eq(tagID) }.delete().execute(db)
  }
}
