import Dependencies
import GalavantSchema
import Observation
import SQLiteData

struct TasteNoteImportSave: Sendable {
  var row: TasteNoteImport.Row
  var plannerID: Planner.ID?
  var ideaID: Idea.ID?
}

@MainActor
@Observable
final class TasteNotesModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @Dependency(\.uuid) private var uuid
  @ObservationIgnored @Dependency(\.date) private var date

  func delete(id: TasteNote.ID) throws {
    try database.write { db in try TasteNote.remove(id: id, in: db) }
  }

  func save(
    existing: TasteNote?, travelPartyID: TravelParty.ID, plannerID: Planner.ID?,
    ideaID: Idea.ID?, placeName: String?, body: String, sourceDetail: String?
  ) throws {
    try database.write { db in
      if let existing {
        try TasteNote.edit(id: existing.id, plannerID: plannerID, ideaID: ideaID,
          placeName: placeName, body: body, sourceDetail: sourceDetail, in: db)
      } else {
        try TasteNote.add(id: uuid(), travelPartyID: travelPartyID, plannerID: plannerID,
          ideaID: ideaID, placeName: placeName, body: body, notedAt: date(), in: db)
      }
    }
  }

  func saveImported(_ entries: [TasteNoteImportSave], travelPartyID: TravelParty.ID) throws {
    try database.write { db in
      for entry in entries {
        try TasteNote.add(id: uuid(), travelPartyID: travelPartyID, plannerID: entry.plannerID,
          ideaID: entry.ideaID, placeName: entry.row.placeName, body: entry.row.body,
          source: .conversation, sourceDetail: entry.row.sourceDetail,
          notedAt: entry.row.notedAt ?? date(), in: db)
      }
    }
  }
}
