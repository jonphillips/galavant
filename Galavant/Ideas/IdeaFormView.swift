import Dependencies
import GalavantSchema
import SQLiteData
import SwiftUI

struct IdeaFormView: View {
  @State var draft: Idea.Draft
  @Environment(\.dismiss) private var dismiss
  @Dependency(\.defaultDatabase) private var database

  var body: some View {
    NavigationStack {
      Form {
        TextField("Name", text: $draft.name)
        Picker("Kind", selection: $draft.kind) {
          Text("Unspecified").tag(IdeaKind?.none)
          ForEach(IdeaKind.allCases, id: \.self) { kind in
            Label(kind.label, systemImage: kind.systemImage).tag(IdeaKind?.some(kind))
          }
        }
        TextField(
          "Region",
          text: Binding(
            get: { draft.regionName ?? "" },
            set: { draft.regionName = $0.isEmpty ? nil : $0 }
          )
        )
        TextField("Link", text: $draft.url)
          .textContentType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        Toggle("Visited", isOn: $draft.visited)
        Section("Notes") {
          TextEditor(text: $draft.notes)
            .frame(minHeight: 120)
        }
      }
      .navigationTitle(draft.id == nil ? "New Idea" : "Edit Idea")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { saveButtonTapped() }
            .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }

  private func saveButtonTapped() {
    withErrorReporting {
      try database.write { db in
        var draft = draft
        draft.travelPartyID = try TravelParty.ensureDefault(in: db).id
        try Idea.upsert { draft }.execute(db)
      }
    }
    dismiss()
  }
}
