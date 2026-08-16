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
  @ObservationIgnored @Dependency(\.date) var now
  @ObservationIgnored @FetchAll(Tag.order(by: \.name)) var allTags

  var draft: Idea.Draft
  var tagNames: [String] = []
  /// The hand-editable structured weekday hours (ADR-0029 §5), decoded from the draft.
  /// The editor mutates this; `structuredHoursEdited()` writes it back to the draft
  /// and stamps `.manual` so the edit wins over re-enrichment.
  var weeklyHours: WeeklyHours = .unknown
  var newTag = ""
  /// True while the field-supplement ladder is running (ADR-0016 §2).
  var supplementingHours = false
  /// Set to present the human-in-the-loop browser (rung 3) when the cheaper rungs
  /// can't find hours — the page the user drives to grab them from.
  var hoursBrowserURL: URL?
  /// A short result line shown after a refresh-hours attempt so the action isn't
  /// silent — a hit, an already-current no-op, or nothing found.
  var hoursStatus: String?
  /// True while the guide-rating fallback is running (ADR-0023).
  var findingGuideRating = false
  /// Set to present the in-app browser pointed at a guide-detail page whose plain
  /// fetch came back empty (the JS-heavy case) — the user renders it, then "Use This
  /// Page" reads the rating off the DOM (ADR-0023, the ADR-0021 HITL fallback).
  var guideBrowserURL: URL?
  /// A short result line for the guide-rating affordance, so it's never silent.
  var guideRatingStatus: String?
  /// The idea's stored images, header first (M4g/M4h). The user can re-pick the
  /// cover from here; the header the enrichment chose (Vision-recommended) is the
  /// default. Empty for a new idea or one without images.
  var images: [ImageAsset] = []
  /// True while the user-requested image refresh is running.
  var refetchingImages = false
  /// A short result line shown after an image refresh attempt.
  var imagesStatus: String?

  init(draft: Idea.Draft) {
    self.draft = draft
    self.weeklyHours = draft.weeklyHours ?? .unknown
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

  func task() async {
    await loadTags()
    await loadImages()
  }

  /// The chosen cover image's display bytes, when the idea has one — for a header
  /// preview at the top of the form.
  var coverImage: Data? { images.first(where: \.isHeader)?.display ?? images.first?.display }

  private func loadImages() async {
    guard let id = draft.id else { return }
    await withErrorReporting {
      images = try await database.read { db in try ImageAsset.images(forIdea: id, in: db) }
    }
  }

  /// Re-pick the cover image (overrides the enrichment's Vision choice). Reloads so
  /// the header floats to the front and the preview updates.
  func setHeader(_ image: ImageAsset) async {
    guard let id = draft.id else { return }
    await withErrorReporting {
      try await database.write { db in
        try ImageAsset.setHeader(image.id, ideaID: id, in: db)
      }
    }
    await loadImages()
  }

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

  /// Whether the supplement affordance applies — only a saved idea (it writes by
  /// id) that has somewhere to look (a link or a location).
  var canSupplementHours: Bool {
    !isNew && (!draft.url.isEmpty || hasLocation)
  }

  /// Climb the cheapest-source ladder to fill opening hours (ADR-0016 §2). On a hit
  /// the form refreshes from the DB; when no cheap rung can, offer the in-app
  /// browser (rung 3) pointed at the idea's own link.
  func supplementHours() async {
    guard let id = draft.id else { return }
    supplementingHours = true
    hoursStatus = nil
    defer { supplementingHours = false }
    let outcome = await FieldSupplement().supplementHours(ideaID: id)
    switch outcome {
    case .filled:
      await reloadHours()
      hoursStatus = "Hours updated."
    case .alreadyPresent:
      hoursStatus = "Already up to date."
    case .notFound:
      if !draft.url.isEmpty, let url = URL(string: draft.url) {
        hoursStatus = "No hours found — opening the page to check."
        hoursBrowserURL = url
      } else {
        hoursStatus = "No hours found, and no link to check."
      }
    }
  }

  /// Apply hours grabbed from the in-app browser's loaded page (rung 3), stamped
  /// `.unverified`, then refresh the form. Returns whether the page yielded any.
  @discardableResult
  func applyBrowsedHours(html: String, sourceURL: URL?) async -> Bool {
    guard let id = draft.id else { return false }
    let filled = await FieldSupplement().applyBrowsedHours(html: html, sourceURL: sourceURL, ideaID: id)
    if filled { await reloadHours() }
    return filled
  }

  /// Whether the guide-rating affordance applies — a saved idea (it writes by id) with
  /// a link to start the guide-link search from.
  var canFindGuideRating: Bool {
    !isNew && !draft.url.isEmpty
  }

  /// Whether the image gallery can be refreshed from the idea's own page.
  var canRefetchImages: Bool {
    !isNew && !draft.url.isEmpty
  }

  /// Explicitly re-run the image rung without re-enriching or overwriting any
  /// hand-edited idea facts or manually chosen cover image.
  func refetchImages() async {
    guard let id = draft.id, !draft.url.isEmpty else { return }
    refetchingImages = true
    imagesStatus = nil
    defer { refetchingImages = false }
    if await PlaceEnricher().refetchImages(ideaID: id) {
      await loadImages()
      imagesStatus = "Images refreshed."
    } else {
      imagesStatus = "No images found on the linked page."
    }
  }

  /// Re-run the automated guide-link rung on demand (ADR-0021/0023). On a hit the rating
  /// is recorded as a sibling `IdeaEvaluation`; when the guide page won't render to a
  /// plain fetch, open the in-app browser pointed straight at it.
  func supplementGuideRating() async {
    guard let id = draft.id else { return }
    findingGuideRating = true
    guideRatingStatus = nil
    defer { findingGuideRating = false }
    switch await GuideRatingSupplement().supplement(ideaID: id) {
    case .recorded(let count):
      guideRatingStatus =
        count > 0 ? Self.ratingCountMessage(count) : "No new ratings — already up to date."
    case .needsBrowser(let url):
      guideRatingStatus = "Couldn't read the guide page — opening it to check."
      guideBrowserURL = url
    case .noGuideLink:
      guideRatingStatus = "No guide link found on this page."
    case .notReady:
      guideRatingStatus = "Nothing to check — add a link first."
    }
  }

  /// Apply a rating read from the DOM the user rendered in the in-app browser (rung 3,
  /// stamped `.official` — a deterministic recognizer on the guide's own page; ADR-0023).
  /// Returns whether the page yielded any rating, mapping the browser's outcome.
  @discardableResult
  func applyBrowsedGuide(html: String, sourceURL: URL?) async -> Bool {
    guard let id = draft.id else { return false }
    let recorded = await GuideRatingSupplement()
      .applyBrowsedGuide(html: html, sourceURL: sourceURL, ideaID: id)
    guard let recorded else { return false }
    guideRatingStatus =
      recorded > 0 ? Self.ratingCountMessage(recorded) : "Found a rating you already had."
    return true
  }

  private static func ratingCountMessage(_ count: Int) -> String {
    "Recorded \(count) rating\(count == 1 ? "" : "s")."
  }

  /// Pull the persisted hours fields back into the draft after a supplement write.
  private func reloadHours() async {
    guard let id = draft.id else { return }
    await withErrorReporting {
      if let idea = try await database.read({ db in try Idea.find(id).fetchOne(db) }) {
        draft.openingHours = idea.openingHours
        draft.hoursProvenance = idea.hoursProvenance
        draft.hoursVerifiedAt = idea.hoursVerifiedAt
        draft.structuredHours = idea.structuredHours
        weeklyHours = idea.weeklyHours ?? .unknown
      }
    }
  }

  /// Commit a hand edit of the structured weekday hours (ADR-0029 §5): encode into the
  /// draft and stamp `hoursProvenance = .manual` + a fresh verified-at, so the edit wins
  /// over re-enrichment. Called by the editor on every change; `Idea.save` persists it.
  func structuredHoursEdited() {
    draft.weeklyHours = weeklyHours.hasAnyAssertion ? weeklyHours : nil
    draft.hoursProvenance = .manual
    draft.hoursVerifiedAt = now.now
  }

  @discardableResult
  func saveButtonTapped() -> Idea.ID? {
    let tagNames = tagNames
    let draft = draft
    return withErrorReporting {
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
