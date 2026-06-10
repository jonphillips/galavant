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
        TextField(
          "Region",
          text: Binding(
            get: { draft.regionName ?? "" },
            set: { draft.regionName = $0.isEmpty ? nil : $0 }
          )
        )
        Section("Notes") {
          TextEditor(text: $draft.notes)
            .frame(minHeight: 120)
        }
      }
      .navigationTitle(draft.id == nil ? "New Idea" : "Edit Idea")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            saveButtonTapped()
          }
        }
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
      }
    }
  }

  private func saveButtonTapped() {
    withErrorReporting {
      try database.write { db in
        try Idea.upsert { draft }.execute(db)
      }
    }
    dismiss()
  }
}
