import GalavantSchema
import SwiftUI

struct TagManagementSettingsView: View {
  @State private var model = TagManagementSettingsModel()
  @State private var renaming: Tag?
  @State private var deleting: Tag?
  @State private var confirmingDeleteUnused = false
  @State private var name = ""

  var body: some View {
    let index = model.index
    let unusedCount = index.tags.filter { index.useCount(for: $0.id) == 0 }.count
    let deletePrompt = deletePrompt(for: deleting, index: index)
    return List {
      if unusedCount > 0 {
        Section {
          Button("Delete Unused Tags (\(unusedCount))",
            systemImage: Icon.delete.systemName, role: .destructive) {
              confirmingDeleteUnused = true
            }
        }
      }
      ForEach(index.tags) { tag in
        HStack {
          Button {
            renaming = tag
            name = tag.name
          } label: {
            HStack {
              Text(tag.name).foregroundStyle(.primary)
              Spacer()
              Text(useDescription(for: tag, index: index))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityHint("Rename tag")
        }
        .swipeActions {
          Button(role: .destructive) {
            if index.useCount(for: tag.id) == 0 {
              model.delete(tag)
            } else {
              deleting = tag
            }
          } label: {
            Label("Delete", systemImage: Icon.delete.systemName)
          }
        }
      }
    }
    .navigationTitle("Tags")
    .overlay {
      if index.tags.isEmpty {
        ContentUnavailableView(
          "No tags yet",
          systemImage: Icon.tag.systemName,
          description: Text("Add tags to an idea from its editor.")
        )
      }
    }
    .task { model.convergeDuplicates() }
    .alert("Rename tag", isPresented: Binding(
      get: { renaming != nil }, set: { if !$0 { renaming = nil } }
    )) {
      TextField("Name", text: $name)
      Button("Save") {
        if let renaming { model.rename(renaming, to: name) }
        renaming = nil
      }
      Button("Cancel", role: .cancel) { renaming = nil }
    } message: {
      if let renaming, let collision = renameCollision(for: renaming, name: name, index: index) {
        Text("Merges with the existing tag “\(collision.name)”.")
      }
    }
    .confirmationDialog(deletePrompt, isPresented: Binding(
      get: { deleting != nil }, set: { if !$0 { deleting = nil } }
    ), titleVisibility: .visible) {
      Button("Remove Tag", role: .destructive) {
        if let deleting { model.delete(deleting) }
        deleting = nil
      }
      Button("Cancel", role: .cancel) { deleting = nil }
    }
    .confirmationDialog("Delete all unused tags?", isPresented: $confirmingDeleteUnused) {
      Button("Delete Unused Tags", role: .destructive) { model.deleteUnused() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes \(unusedCount) tags that aren't used by any ideas.")
    }
  }

  private func deletePrompt(for deleting: Tag?, index: TagIndex) -> String {
    guard let deleting else { return "Remove tag?" }
    let count = index.useCount(for: deleting.id)
    return count == 0
      ? "Delete “\(deleting.name)”?"
      : "Remove “\(deleting.name)” from \(count) \(count == 1 ? "idea" : "ideas")?"
  }

  private func useDescription(for tag: Tag, index: TagIndex) -> String {
    let count = index.useCount(for: tag.id)
    if count == 0 { return "Unused" }
    return "\(count) \(count == 1 ? "idea" : "ideas")"
  }

  private func renameCollision(for tag: Tag, name: String, index: TagIndex) -> Tag? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return index.tags.first {
      $0.id != tag.id
        && $0.travelPartyID == tag.travelPartyID
        && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
    }
  }
}
