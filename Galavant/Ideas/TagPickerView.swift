import GalavantSchema
import SwiftUI

/// The "manage many" tag surface (BACKLOG "Multi-select tag assignment on Ideas",
/// 2026-06-13): every existing tag as a checkmark row, toggled independently — the
/// one-at-a-time inline add in `IdeaFormView`'s Tags section stays as the quick path.
/// Both write through the same `IdeaFormModel.addTagName`/`removeTagName`; this view
/// invents no parallel persistence. `Idea.save` (PoolOperations.swift) reconciles
/// `tagNames` against the `IdeaTag` join on save, so toggling here is just editing the
/// in-memory draft like the inline chips do.
///
/// Pushed via `NavigationLink` from the form's own `NavigationStack` (the sheet's
/// stack, not the iPad split-view detail column's — see the nested-NavigationStack
/// trap in jon-platform's `ui-and-platforms.md`), so a normal push-with-back is safe
/// here.
struct TagPickerView: View {
  let model: IdeaFormModel
  @State private var newTagName = ""
  @FocusState private var newTagFieldFocused: Bool

  var body: some View {
    List {
      Section {
        ForEach(model.allTags) { tag in
          Button {
            toggle(tag.name)
          } label: {
            HStack {
              Icon.tag.image.foregroundStyle(.secondary)
              Text(tag.name).foregroundStyle(.primary)
              Spacer()
              if isSelected(tag.name) {
                Icon.checkmark.image.foregroundStyle(.tint)
              }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      } footer: {
        if model.allTags.isEmpty {
          Text("No tags yet — add one below.")
        }
      }

      Section {
        TextField("New tag", text: $newTagName)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .focused($newTagFieldFocused)
          .onSubmit(addNewTag)
        if !trimmedNewTagName.isEmpty, !matchesExistingTag {
          Button {
            addNewTag()
          } label: {
            Icon.addInline.label("Add “\(trimmedNewTagName)”")
          }
        }
      }
    }
    .navigationTitle("Select Tags")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var trimmedNewTagName: String {
    newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var matchesExistingTag: Bool {
    model.allTags.contains { $0.name.caseInsensitiveCompare(trimmedNewTagName) == .orderedSame }
  }

  private func isSelected(_ name: String) -> Bool {
    model.tagNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
  }

  private func toggle(_ name: String) {
    if isSelected(name) {
      model.removeTagName(name)
    } else {
      model.addTagName(name)
    }
  }

  private func addNewTag() {
    guard !trimmedNewTagName.isEmpty else { return }
    model.addTagName(trimmedNewTagName)
    newTagName = ""
  }
}
