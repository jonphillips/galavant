import Dependencies
import GalavantSchema
import MapKit
import SQLiteData
import SwiftUI

struct IdeaFormView: View {
  @State var draft: Idea.Draft
  @State private var search = LocationSearchModel()
  @State private var tagNames: [String] = []
  @State private var newTag = ""
  @FocusState private var tagFieldFocused: Bool
  @FetchAll(Tag.order(by: \.name)) private var allTags
  @Environment(\.dismiss) private var dismiss
  @Dependency(\.defaultDatabase) private var database

  private var hasLocation: Bool {
    draft.latitude != nil && draft.longitude != nil
  }

  private var trimmedNewTag: String {
    newTag.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var unusedSuggestions: [String] {
    allTags.map(\.name)
      .filter { name in !tagNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
      .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  /// Existing tags matching what's being typed (autocomplete).
  private var matchingSuggestions: [String] {
    unusedSuggestions.filter { $0.localizedCaseInsensitiveContains(trimmedNewTag) }
  }

  /// True when the typed text already names a tag (added or not) — so don't
  /// offer to create a duplicate.
  private var typedMatchesExisting: Bool {
    (allTags.map(\.name) + tagNames).contains {
      $0.caseInsensitiveCompare(trimmedNewTag) == .orderedSame
    }
  }

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

        Section("Location") {
          if hasLocation {
            HStack {
              Image(systemName: "mappin.circle.fill")
                .foregroundStyle(.red)
              VStack(alignment: .leading) {
                Text(draft.name.isEmpty ? "Pinned location" : draft.name)
                if let regionName = draft.regionName, !regionName.isEmpty {
                  Text(regionName).font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer()
              Button("Clear", role: .destructive) { clearLocation() }
                .buttonStyle(.borderless)
            }
          } else {
            TextField("Search a place", text: $search.query)
              .textInputAutocapitalization(.words)
            ForEach(search.results, id: \.self) { completion in
              Button {
                Task { await pickPlace(completion) }
              } label: {
                VStack(alignment: .leading) {
                  Text(completion.title).foregroundStyle(.primary)
                  if !completion.subtitle.isEmpty {
                    Text(completion.subtitle).font(.caption).foregroundStyle(.secondary)
                  }
                }
              }
            }
          }
        }

        Section("Tags") {
          ForEach(tagNames, id: \.self) { name in
            HStack {
              Image(systemName: "tag").foregroundStyle(.secondary)
              Text(name)
              Spacer()
              Button(role: .destructive) {
                tagNames.removeAll { $0 == name }
              } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
              }
              .buttonStyle(.borderless)
            }
          }
          TextField("Add a tag", text: $newTag)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($tagFieldFocused)
            .onSubmit { addTagName(trimmedNewTag) }
          if tagFieldFocused || !trimmedNewTag.isEmpty {
            // On focus (empty) show all available tags; narrow as you type.
            ForEach(trimmedNewTag.isEmpty ? unusedSuggestions : matchingSuggestions, id: \.self) { name in
              Button { addTagName(name) } label: {
                Label(name, systemImage: "tag")
              }
            }
            if !trimmedNewTag.isEmpty, !typedMatchesExisting {
              Button { addTagName(trimmedNewTag) } label: {
                Label("Add “\(trimmedNewTag)”", systemImage: "plus.circle")
              }
            }
          }
        }

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
      .task { await loadTags() }
    }
  }

  private func addTagName(_ name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    defer { newTag = "" }
    guard
      !trimmed.isEmpty,
      !tagNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
    else { return }
    tagNames.append(trimmed)
  }

  private func loadTags() async {
    guard let id = draft.id else { return }
    await withErrorReporting {
      tagNames = try await database.read { db in
        try IdeaTag.where { $0.ideaID.eq(id) }
          .fetchAll(db)
          .compactMap { try Tag.find($0.tagID).fetchOne(db)?.name }
          .sorted()
      }
    }
  }

  private func pickPlace(_ completion: MKLocalSearchCompletion) async {
    guard let place = await search.resolve(completion) else { return }
    if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
      draft.name = place.name
    }
    draft.latitude = place.latitude
    draft.longitude = place.longitude
    draft.regionName = place.regionName
    search.query = ""
  }

  private func clearLocation() {
    draft.latitude = nil
    draft.longitude = nil
  }

  private func saveButtonTapped() {
    let tagNames = tagNames
    let draft = draft
    withErrorReporting {
      try database.write { db in
        let ideaID = draft.id ?? UUID()
        // Draft.id is a `let`, so rebuild with a guaranteed id + party.
        let saving = Idea.Draft(
          id: ideaID,
          name: draft.name,
          notes: draft.notes,
          kind: draft.kind,
          regionName: draft.regionName,
          latitude: draft.latitude,
          longitude: draft.longitude,
          url: draft.url,
          visited: draft.visited,
          travelPartyID: try TravelParty.ensureDefault(in: db).id
        )
        try Idea.upsert { saving }.execute(db)

        let desired = try Set(tagNames.map { try Tag.findOrCreate(named: $0, in: db).id })
        let existing = try Set(
          IdeaTag.where { $0.ideaID.eq(ideaID) }.fetchAll(db).map(\.tagID)
        )
        for tagID in desired.subtracting(existing) {
          try IdeaTag.add(tagID: tagID, to: ideaID, in: db)
        }
        for tagID in existing.subtracting(desired) {
          try IdeaTag.remove(tagID: tagID, from: ideaID, in: db)
        }
      }
    }
    dismiss()
  }
}
