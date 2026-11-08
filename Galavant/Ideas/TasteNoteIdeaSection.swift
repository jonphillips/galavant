import GalavantSchema
import SQLiteData
import SwiftUI

/// Editable list in the Idea form; observation is scoped to notes, not TripPlan.
struct TasteNoteIdeaSection: View {
  let travelPartyID: TravelParty.ID
  let ideaID: Idea.ID
  @FetchAll(TasteNote.order { $0.notedAt.desc() }) private var allNotes
  @FetchAll(Planner.all) private var planners
  @State private var adding = false
  @State private var editing: TasteNote?

  private var notes: [TasteNote] { allNotes.filter { $0.ideaID == ideaID } }

  var body: some View {
    Section("Taste Notes") {
      ForEach(notes) { note in
        Button { editing = note } label: {
          VStack(alignment: .leading, spacing: 3) {
            Text(note.body).foregroundStyle(.primary)
            Text("\(note.plannerID.flatMap { id in planners.first { $0.id == id }?.displayName } ?? "Both of us") · \(note.notedAt.formatted(date: .abbreviated, time: .omitted))")
              .font(.caption).foregroundStyle(.secondary)
          }
        }.buttonStyle(.plain)
      }
      Button { adding = true } label: { Label("Add Taste Note", systemImage: "plus") }
    }
    .sheet(isPresented: $adding) {
      TasteNoteEditorSheet(travelPartyID: travelPartyID, planners: planners, initialIdeaID: ideaID)
    }
    .sheet(item: $editing) { note in
      TasteNoteEditorSheet(travelPartyID: travelPartyID, planners: planners, existing: note)
    }
  }
}
