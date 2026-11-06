import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import SQLiteData
import Testing

@Suite(.dependencies { try $0.bootstrapDatabase() })
struct TasteNoteTests {
  @Dependency(\.defaultDatabase) var database

  @Test func promptLinesAreNewestFirstAndSayWhatWasOmitted() {
    let partyID = UUID()
    let planner = Planner(id: UUID(), displayName: "Jon", travelPartyID: partyID)
    let older = TasteNote(id: UUID(), travelPartyID: partyID, plannerID: planner.id,
      placeName: "Cafe North", body: "Quiet lunches work best.", notedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let newer = TasteNote(id: UUID(), travelPartyID: partyID, body: "Avoid long formal meals.",
      notedAt: Date(timeIntervalSince1970: 1_710_000_000))
    let lines = TasteNote.promptLines(notes: [older, newer], planners: [planner], limit: 1)
    #expect(lines.count == 3)
    #expect(lines[0].contains("own words"))
    #expect(lines[1].contains("Avoid long formal meals"))
    #expect(lines[2].contains("1 taste note omitted"))
    #expect(older.subject == .place(name: "Cafe North", ideaID: nil))
  }

  @Test func promptLinesCoverGeneralNotesAndTheCharacterLimit() {
    let note = TasteNote(id: UUID(), travelPartyID: UUID(), body: "A", notedAt: Date(timeIntervalSince1970: 0))
    let lines = TasteNote.promptLines(notes: [note], planners: [])
    #expect(lines.count == 2)
    #expect(lines[1].contains("general travel taste"))
    #expect(TasteNote.promptLines(notes: [note], planners: [], characterLimit: 70).last?.contains("omitted") == true)
    #expect(TasteNote.promptLines(notes: [], planners: []).isEmpty)
  }

  @Test func noteSurvivesIdeaAndPlannerDeletion() async throws {
    let note = try await database.write { db -> TasteNote in
      let party = try TravelParty.ensureDefault(in: db)
      let plannerID = UUID()
      let ideaID = UUID()
      try Planner.insert { Planner.Draft(Planner(id: plannerID, displayName: "Jon", travelPartyID: party.id)) }.execute(db)
      try Idea.insert { Idea.Draft(Idea(id: ideaID, name: "Fictional Cafe", travelPartyID: party.id)) }.execute(db)
      let noteID = try TasteNote.add(id: UUID(), travelPartyID: party.id, plannerID: plannerID,
        ideaID: ideaID, placeName: nil, body: "Invented fixture words.", notedAt: Date(timeIntervalSince1970: 1_700_000_000), in: db)
      try Idea.find(ideaID).delete().execute(db)
      try Planner.deletePlanner(id: plannerID, in: db)
      guard let note = try TasteNote.find(noteID).fetchOne(db) else { throw TasteNoteError.noteNotFound }
      return note
    }
    #expect(note.placeName == "Fictional Cafe")
    #expect(note.plannerID == nil)
    #expect(note.subject == .place(name: "Fictional Cafe", ideaID: note.ideaID))
  }

  @Test func addingRejectsEmptyBody() async throws {
    await #expect(throws: TasteNoteError.emptyBody) {
      try await database.write { db in
        let party = try TravelParty.ensureDefault(in: db)
        try TasteNote.add(id: UUID(), travelPartyID: party.id, plannerID: nil,
          ideaID: nil, placeName: nil, body: " \n ", notedAt: Date(), in: db)
      }
    }
  }

  @Test func mergedIdeaRepointsItsNotesToTheSurvivor() async throws {
    let pair = try await database.write { db -> (UUID, UUID) in
      let party = try TravelParty.ensureDefault(in: db)
      let oldID = UUID()
      let survivorID = UUID()
      try Idea.insert { Idea.Draft(Idea(id: oldID, name: "Old name", travelPartyID: party.id)) }.execute(db)
      try Idea.insert { Idea.Draft(Idea(id: survivorID, name: "Survivor Cafe", travelPartyID: party.id)) }.execute(db)
      let noteID = try TasteNote.add(id: UUID(), travelPartyID: party.id, plannerID: nil,
        ideaID: oldID, placeName: nil, body: "A note to keep.", notedAt: Date(), in: db)
      try TasteNote.repoint(from: oldID, to: survivorID, travelPartyID: party.id, in: db)
      let note = try TasteNote.find(noteID).fetchOne(db)
      #expect(note?.ideaID == survivorID)
      #expect(note?.placeName == "Survivor Cafe")
      return (oldID, survivorID)
    }
    #expect(pair.0 != pair.1)
  }

  @Test func partyConvergenceKeepsTasteNotesAndRepointsTheirParty() async throws {
    let survivorID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let otherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let noteID = try await database.write { db -> UUID in
      try TravelParty.insert { TravelParty.Draft(TravelParty(id: survivorID)) }.execute(db)
      try TravelParty.insert { TravelParty.Draft(TravelParty(id: otherID)) }.execute(db)
      let id = UUID()
      try TasteNote.insert { TasteNote.Draft(TasteNote(
        id: id, travelPartyID: otherID, body: "Preserve me.", notedAt: Date()
      )) }.execute(db)
      let party = try TravelParty.ensureDefault(in: db)
      #expect(party.id == otherID)
      return id
    }
    let note = try await database.read { db in try TasteNote.find(noteID).fetchOne(db) }
    #expect(note?.travelPartyID == otherID)
    #expect(note?.body == "Preserve me.")
  }

  @Test func conversationReturnRejectsMalformedAndReportsMissingRows() throws {
    #expect(throws: TasteNoteImportError.malformedJSON) { try TasteNoteImport.decode("not json") }
    let result = try TasteNoteImport.decode(#"GV-NOTES {"notes":[{"note":"An invented preference","words":"summary","who":"someone","place":"Lago Verde"},{"place":"No body"}]}"#)
    #expect(result.rows.count == 1)
    #expect(result.rows[0].isSummary)
    #expect(result.rows[0].who == "both")
    #expect(result.warnings.count == 1)
  }
}
