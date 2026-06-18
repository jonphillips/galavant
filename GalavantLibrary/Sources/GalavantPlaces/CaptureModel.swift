import Dependencies
import Foundation
import GalavantCapture
import GalavantImaging
import GalavantSchema
import SQLiteData

/// The capture flow's view-model — drives the share-extension confirm sheet
/// (Jon's choice: vet captures at the source). It parses the shared page, refines
/// the location via Apple Maps, exposes an **editable** draft for confirm-and-tweak,
/// and saves to the app-group database. Lives in the package (not the extension
/// shell) so the parse→match→save logic is testable with an in-memory DB and
/// fixture clients; the extension only hosts the SwiftUI view over it.
///
/// Single-hop by design (M4c): the place's `websiteURL` is preserved on the saved
/// idea so the app can take the deferred second enrichment hop later.
@MainActor
@Observable
public final class CaptureModel {
  public enum Phase: Equatable, Sendable {
    case preparing
    case ready
    case saving
    case saved
    case failed(String)
  }

  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @Dependency(\.placeMatcher) private var placeMatcher
  @ObservationIgnored @Dependency(\.placeIntelligence) private var placeIntelligence
  @ObservationIgnored @Dependency(\.imageFetcher) private var imageFetcher
  @ObservationIgnored @Dependency(\.recentTripStore) private var recentTripStore
  @ObservationIgnored @Dependency(\.uuid) private var uuid

  private let html: String
  private let sourceURL: URL?

  public private(set) var phase: Phase = .preparing
  /// The editable idea the confirm sheet binds to (name/kind/notes/url/…).
  public var draft = Idea.Draft()
  /// The active trips the capture can be pulled onto, the most-recently-used one
  /// first (and pre-selected); the rest in lifecycle/chronological order. Empty
  /// when there are no active trips — the sheet then offers the pool only.
  public private(set) var trips: [Trip] = []
  /// The trip to pull this idea onto, or nil for "None" (pool only). Bound by the
  /// confirm sheet's trip picker.
  public var selectedTripID: Trip.ID?
  /// Carry-over signals the `Idea` schema doesn't hold yet (images, hours, the
  /// second-hop `websiteURL`) — kept for the deferred app-side enrichment.
  public private(set) var captured: CapturedPlace?

  public init(html: String, sourceURL: URL?) {
    self.html = html
    self.sourceURL = sourceURL
  }

  /// Parse the page and refine its location. Idempotent-ish — call once on appear.
  public func prepare() async {
    var page = PageParser.parse(html: html, sourceURL: sourceURL)
    // On-device Apple Intelligence refines the parse before matching — a cleaned
    // name and a mined city feed both the draft and the Apple Maps query (so a
    // name-only page like koancph.dk can resolve). Confirm-and-tweak: it only
    // fills blanks / cleans chrome titles, and is a no-op when unavailable.
    let refinement = await placeIntelligence(page)
    if let refinement { page = page.applying(refinement) }
    let captured = CapturedPlace.from(page, id: uuid())
    var draft = captured.draft
    // Kind is domain (not on the domain-free ParsedPage): apply the model's
    // classification only when the structured `schema.org` type left it blank.
    if draft.kind == nil, let kind = refinement?.kind { draft.kind = kind }

    if let match = await placeMatcher.match(page) {
      draft.latitude = match.coordinate.latitude
      draft.longitude = match.coordinate.longitude
      // Confirm-and-tweak: only fill what the page left blank (like search-first).
      // Apple Maps is a rich enrichment source, so take its name/address/region/
      // kind/phone/link too — but never clobber what the page already supplied.
      // Name is special: a *structured* page name is trusted, but a chrome-derived
      // title (a clipped marketing string) is only a guess, so a confident Apple
      // Maps name — one that overlaps ours, so it's the same place — wins over it.
      if let matchName = match.name, !matchName.isEmpty {
        if draft.name.isEmpty {
          draft.name = matchName
        } else if !page.titleIsStructured,
          PlaceMatching.significantCommonWordCount(matchName, draft.name) > 0
        {
          draft.name = matchName
        }
      }
      if draft.address == nil, let address = match.address { draft.address = address }
      if draft.regionName == nil, let regionName = match.regionName { draft.regionName = regionName }
      if draft.kind == nil, let kind = match.kind { draft.kind = kind }
      if draft.phone == nil, let phone = match.phone { draft.phone = phone }
      if draft.url.isEmpty, let url = match.url { draft.url = url }
    }

    self.captured = captured
    self.draft = draft
    await self.loadTrips()
    self.phase = .ready
  }

  /// Load the active trips for the picker: the most-recently-used trip first and
  /// pre-selected, then the rest in the app's lifecycle order (dated → targeted →
  /// top someday, dated chronologically). Defaults to "None" when there's no recent
  /// trip among the active ones.
  private func loadTrips() async {
    let allTrips = (try? await database.read { db in try Trip.all.fetchAll(db) }) ?? []
    var ordered = Trip.activeCapsules(allTrips)
    if let recentID = recentTripStore.read(),
      let index = ordered.firstIndex(where: { $0.id == recentID })
    {
      ordered.insert(ordered.remove(at: index), at: 0)
      selectedTripID = recentID
    }
    trips = ordered
  }

  /// Apply a location the user picked in the confirm sheet's search — the escape
  /// hatch when the automatic match is wrong (or absent, as with koancph.dk). The
  /// chosen place is authoritative for the coordinate/address/region; name, kind,
  /// and link stay confirm-and-tweak (only filled when the page left them blank,
  /// so a deliberate edit isn't clobbered).
  public func useLocation(_ place: Place) {
    draft.latitude = place.latitude
    draft.longitude = place.longitude
    draft.address = place.address
    draft.regionName = place.regionName
    if draft.name.isEmpty { draft.name = place.name }
    if draft.kind == nil { draft.kind = place.kind }
    if draft.phone == nil { draft.phone = place.phone }
    if draft.url.isEmpty, let url = place.url { draft.url = url }
  }

  /// Drop the resolved location, leaving it for the user to re-search or fill in
  /// the app later.
  public func clearLocation() {
    draft.latitude = nil
    draft.longitude = nil
    draft.address = nil
    draft.regionName = nil
  }

  /// The processed header image to store with this capture, or nil when there's no
  /// candidate or the fetch/decode failed. Pulls only the best candidate
  /// (`imageURLs.first` — the parser's structured-source-first ordering) and shrinks
  /// it to the display + thumbnail tiers (ADR-0009).
  private struct PreparedImage {
    var display: Data
    var thumbnail: Data
    var sourceURL: String
    var id: UUID
  }

  private func prepareHeaderImage() async -> PreparedImage? {
    guard let url = captured?.imageURLs.first else { return nil }
    guard let data = await imageFetcher(url) else { return nil }
    guard let processed = ImageProcessing.process(data) else { return nil }
    return PreparedImage(
      display: processed.display,
      thumbnail: processed.thumbnail,
      sourceURL: url.absoluteString,
      id: uuid()
    )
  }

  /// Save the (possibly edited) draft into the shared pool under the default
  /// travel party, so it rides the travel-party CloudKit share (ADR-0003).
  public func save() async {
    phase = .saving
    // Hybrid capture (M4f): fetch + shrink just the single best candidate here in
    // the extension (one image stays well inside the ~120 MB budget) so the idea
    // lands with a header image; the full ranked gallery is the app's job (M4g).
    // Best-effort — a missing/undecodable image never blocks the save.
    let headerImage = await prepareHeaderImage()
    // Capture only Sendable scalars into the DB write — `Idea.Draft` itself isn't
    // Sendable (the @Table-generated type), so rebuild it inside the closure.
    let id = draft.id
    let name = draft.name
    let notes = draft.notes
    let kind = draft.kind
    let regionName = draft.regionName
    let address = draft.address
    let phone = draft.phone
    let latitude = draft.latitude
    let longitude = draft.longitude
    let url = draft.url
    let tripID = selectedTripID
    let imageDisplay = headerImage?.display
    let imageThumbnail = headerImage?.thumbnail
    let imageSourceURL = headerImage?.sourceURL
    let imageID = headerImage?.id
    do {
      try await database.write { db in
        let party = try TravelParty.ensureDefault(in: db)
        try Idea.insert {
          Idea.Draft(
            id: id,
            name: name,
            notes: notes,
            kind: kind,
            regionName: regionName,
            address: address,
            phone: phone,
            latitude: latitude,
            longitude: longitude,
            url: url,
            travelPartyID: party.id
          )
        }
        .execute(db)
        // Pull onto the chosen trip (idempotent) so the capture lands as a
        // "considering" entry, not just in the eternal pool.
        if let tripID, let id {
          try TripIdea.pull(ideaID: id, into: tripID, in: db)
        }
        // Store the header image alongside the idea, in the same transaction.
        if let id, let imageDisplay, let imageThumbnail, let imageID {
          try ImageAsset.store(
            ideaID: id,
            display: imageDisplay,
            thumbnail: imageThumbnail,
            sourceURL: imageSourceURL,
            asHeader: true,
            id: imageID,
            in: db
          )
        }
      }
      // Remember the trip so the next capture defaults to the same one.
      if let tripID { recentTripStore.record(tripID) }
      phase = .saved
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }
}
