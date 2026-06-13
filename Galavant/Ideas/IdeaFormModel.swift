import Dependencies
import Foundation
import GalavantSchema
import SQLiteData

/// Owns an idea being created/edited: the draft, its tags, and all persistence
/// (party resolution, upsert, tag reconciliation). The view stays presentation.
@MainActor
@Observable
final class IdeaFormModel {
  @ObservationIgnored @Dependency(\.defaultDatabase) var database
  @ObservationIgnored @FetchAll(Tag.order(by: \.name)) var allTags

  var draft: Idea.Draft
  var tagNames: [String] = []
  var newTag = ""

  init(draft: Idea.Draft) {
    self.draft = draft
  }

  var isNew: Bool { draft.id == nil }
  var hasLocation: Bool { draft.latitude != nil && draft.longitude != nil }
  var canSave: Bool { !draft.name.trimmingCharacters(in: .whitespaces).isEmpty }
  var trimmedNewTag: String { newTag.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// Existing tags not yet on this idea, case-insensitively sorted.
  var unusedSuggestions: [String] {
    allTags.map(\.name)
      .filter { name in !tagNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
      .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  var matchingSuggestions: [String] {
    unusedSuggestions.filter { $0.localizedCaseInsensitiveContains(trimmedNewTag) }
  }

  var typedMatchesExisting: Bool {
    (allTags.map(\.name) + tagNames).contains {
      $0.caseInsensitiveCompare(trimmedNewTag) == .orderedSame
    }
  }

  func task() async { await loadTags() }

  func addTagName(_ name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    defer { newTag = "" }
    guard
      !trimmed.isEmpty,
      !tagNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
    else { return }
    tagNames.append(trimmed)
  }

  func removeTagName(_ name: String) {
    tagNames.removeAll { $0 == name }
  }

  func setLocation(_ place: ResolvedPlace) {
    if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
      draft.name = place.name
    }
    draft.latitude = place.latitude
    draft.longitude = place.longitude
    draft.regionName = place.regionName
  }

  func clearLocation() {
    draft.latitude = nil
    draft.longitude = nil
  }

  func saveButtonTapped() {
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
  }

  private func loadTags() async {
    guard let id = draft.id else { return }
    await withErrorReporting {
      tagNames = try await database.read { db in
        try IdeaTag.where { $0.ideaID.eq(id) }
          .fetchAll(db)
          .compactMap { try Tag.find($0.tagID).fetchOne(db)?.name }
          .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
      }
    }
  }
}
