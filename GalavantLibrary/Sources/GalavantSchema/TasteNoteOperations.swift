import Foundation
import SQLiteData

extension TasteNote {
  /// Add a person's own words. A linked idea supplies the durable display name.
  @discardableResult
  public static func add(
    id: UUID, travelPartyID: TravelParty.ID, plannerID: Planner.ID?,
    ideaID: Idea.ID?, placeName: String?, body: String,
    source: TasteNoteSource = .planner, sourceDetail: String? = nil, notedAt: Date, in db: Database
  ) throws -> TasteNote.ID {
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedBody.isEmpty else { throw TasteNoteError.emptyBody }
    let subject = try resolveSubject(ideaID: ideaID, placeName: placeName, travelPartyID: travelPartyID, in: db)
    try TasteNote.insert {
      TasteNote.Draft(TasteNote(
        id: id, travelPartyID: travelPartyID, plannerID: plannerID,
        ideaID: subject.ideaID, placeName: subject.name, body: trimmedBody,
        source: source, sourceDetail: sourceDetail, notedAt: notedAt
      ))
    }.execute(db)
    return id
  }

  /// Edit content while preserving row identity and original noted date.
  public static func edit(
    id: TasteNote.ID, plannerID: Planner.ID?, ideaID: Idea.ID?, placeName: String?,
    body: String, sourceDetail: String?, in db: Database
  ) throws {
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedBody.isEmpty else { throw TasteNoteError.emptyBody }
    guard let existing = try TasteNote.find(id).fetchOne(db) else { throw TasteNoteError.noteNotFound }
    let subject = try resolveSubject(ideaID: ideaID, placeName: placeName,
      travelPartyID: existing.travelPartyID, in: db)
    try TasteNote.find(id).update {
      $0.plannerID = #bind(plannerID)
      $0.ideaID = #bind(subject.ideaID)
      $0.placeName = #bind(subject.name)
      $0.body = #bind(trimmedBody)
      $0.sourceDetail = #bind(sourceDetail)
    }.execute(db)
  }

  public static func remove(id: TasteNote.ID, in db: Database) throws {
    try TasteNote.find(id).delete().execute(db)
  }

  /// Preserve notes when the pool's merge path collapses one idea into another.
  public static func repoint(
    from losingIdeaID: Idea.ID, to survivorIdeaID: Idea.ID,
    travelPartyID: TravelParty.ID, in db: Database
  ) throws {
    guard let survivor = try Idea.find(survivorIdeaID).fetchOne(db) else { throw TasteNoteError.ideaNotFound }
    try TasteNote.where { $0.ideaID.eq(losingIdeaID) && $0.travelPartyID.eq(travelPartyID) }
      .update {
        $0.ideaID = #bind(survivorIdeaID)
        $0.placeName = #bind(survivor.name.nonBlank ?? "Unnamed place")
      }
      .execute(db)
  }

  private static func resolveSubject(
    ideaID: Idea.ID?, placeName: String?, travelPartyID: TravelParty.ID, in db: Database
  ) throws -> (ideaID: Idea.ID?, name: String?) {
    if let ideaID {
      guard let idea = try Idea.find(ideaID).fetchOne(db), idea.travelPartyID == travelPartyID else {
        throw TasteNoteError.ideaNotFound
      }
      return (ideaID, idea.name.nonBlank ?? placeName?.nonBlank ?? "Unnamed place")
    }
    return (nil, placeName?.nonBlank)
  }
}

private extension String {
  var nonBlank: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}

public enum TasteNoteError: Error, Equatable {
  case emptyBody
  case ideaNotFound
  case noteNotFound
}
