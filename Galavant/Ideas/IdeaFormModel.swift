import Dependencies
import Foundation
import GalavantPlaces
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

  /// Search-first fill: location drives the form, but never clobbers what the
  /// user already typed. Name/kind/link fill only when still empty (confirm-and-
  /// tweak); address/phone/region are facts about the place, so they refresh.
  func setLocation(_ place: Place) {
    if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
      draft.name = place.name
    }
    if draft.kind == nil { draft.kind = place.kind }
    if draft.url.isEmpty, let url = place.url { draft.url = url }
    draft.latitude = place.latitude
    draft.longitude = place.longitude
    draft.regionName = place.regionName
    draft.address = place.address
    draft.phone = place.phone
  }

  func clearLocation() {
    draft.latitude = nil
    draft.longitude = nil
    draft.address = nil
    draft.phone = nil
  }

  func saveButtonTapped() {
    let tagNames = tagNames
    let draft = draft
    withErrorReporting {
      try database.write { db in
        try Idea.save(draft, tagNames: tagNames, in: db)
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
