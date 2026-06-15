import GalavantSchema
import SwiftUI

/// Manage tags: rename (updates everywhere, since ideas reference the tag) or
/// delete (also removes the tag from any ideas).
struct TagManagerView: View {
  let model: IdeasListModel
  @Environment(\.dismiss) private var dismiss
  @State private var renaming: Tag?
  @State private var newName = ""

  var body: some View {
    NavigationStack {
      List {
        ForEach(model.sortedTags) { tag in
          Button {
            renaming = tag
            newName = tag.name
          } label: {
            HStack {
              Icon.tag.image.foregroundStyle(.secondary)
              Text(tag.name).foregroundStyle(.primary)
              Spacer()
              Icon.edit.image.foregroundStyle(.secondary)
            }
          }
        }
        .onDelete { model.deleteTags(at: $0) }
      }
      .overlay {
        if model.tags.isEmpty {
          ContentUnavailableView(
            "No tags",
            systemImage: Icon.tag.systemName,
            description: Text("Add tags to an idea to build your vocabulary.")
          )
        }
      }
      .navigationTitle("Tags")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .alert(
        "Rename tag",
        isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
      ) {
        TextField("Name", text: $newName)
        Button("Save") {
          if let tag = renaming { model.renameTag(tag, to: newName) }
          renaming = nil
        }
        Button("Cancel", role: .cancel) { renaming = nil }
      }
    }
  }
}
