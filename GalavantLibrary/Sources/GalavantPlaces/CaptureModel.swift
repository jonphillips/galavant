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
  #if DEBUG
    @ObservationIgnored @Dependency(\.placeSearch) private var placeSearch
  #endif
  @ObservationIgnored @Dependency(\.placeIntelligence) private var placeIntelligence
  @ObservationIgnored @Dependency(\.imageFetcher) private var imageFetcher
  @ObservationIgnored @Dependency(\.recentTripStore) private var recentTripStore
  @ObservationIgnored @Dependency(\.evaluationExtractor) private var evaluationExtractor
  @ObservationIgnored @Dependency(\.uuid) private var uuid
  @ObservationIgnored @Dependency(\.date) private var now

  private let html: String
  private let sourceURL: URL?
  /// Set when the share was a *location* (Apple Maps / vCard, ADR-0020) rather than a
  /// web page — `prepare()` seeds the pipeline from it instead of parsing HTML.
  private let seedLocation: SharedLocation?

  public private(set) var phase: Phase = .preparing
  /// The editable idea the confirm sheet binds to (name/kind/notes/url/…).
  public var draft = Idea.Draft()
  /// Explicit field values set by the browser's tap-to-fill chip bar (ADR-0025 §5).
  /// Set before `prepare()` runs; applied at the end of `prepare()` so user selections
  /// win over auto-parsed values. `nil` = no overrides (the common path).
  public var draftOverrides: CaptureDraftOverride?
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
  /// Source judgments detected on the page (ADR-0016 §1), surfaced in the confirm
  /// sheet so Jon vets them (confirm-and-tweak). Each is `included` by default;
  /// toggling it off drops it from the save. Saved as sibling `IdeaEvaluation`s.
  public var detectedEvaluations: [DetectedEvaluation] = []
  /// An existing pool idea this capture resolves to by Apple Maps identity (ADR-0019),
  /// when one exists — drives the confirm sheet's "already in your pool, will update"
  /// banner so the supplement is never silent (M4c). Advisory: the save transaction
  /// re-checks and is the source of truth, so a race can't double-insert.
  public private(set) var existingMatch: Idea?

  /// The opening-hours string this capture will save — the tap-to-fill override if set,
  /// else the page parser's result. nil when neither produced hours. Surfaced so the
  /// confirm sheet can show what will be saved.
  public var openingHoursDisplay: String? {
    if let override = draftOverrides?.openingHours, !override.isEmpty { return override }
    guard let captured, !captured.openingHours.isEmpty else { return nil }
    return captured.openingHours.joined(separator: "\n")
  }

  #if DEBUG
    /// A read-only trace of the last `prepare()`'s location-match attempt, surfaced
    /// in the confirm sheet so a failed/empty match can be diagnosed on-device
    /// (which parse the page yielded, what the on-device AI refinement changed, the
    /// exact Apple Maps query, and the raw candidates + their scores — separating
    /// "found but scored too low" from "search returned nothing / threw / throttled").
    /// DEBUG-only: it never influences the match decision, only reports it.
    public private(set) var diagnostics: CaptureDiagnostics?
  #endif

  public init(html: String, sourceURL: URL?) {
    self.html = html
    self.sourceURL = sourceURL
    self.seedLocation = nil
  }

  /// Seed the capture from a shared location (Apple Maps place / vCard, ADR-0020)
  /// rather than a web page. `prepare()` synthesizes a `ParsedPage` from it and runs
  /// the same refine → match → dedup → save pipeline.
  public init(location: SharedLocation) {
    self.html = ""
    self.sourceURL = nil
    self.seedLocation = location
  }

  /// Parse the page and refine its location. Idempotent-ish — call once on appear.
  public func prepare() async {
    // A location share seeds a synthesized page (ADR-0020); a web share parses HTML.
    var page = seedLocation?.parsedPage(capturedAt: now.now)
      ?? PageParser.parse(html: html, sourceURL: sourceURL)
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
    // A Maps share may already carry Apple's persistent identity; seed it so the
    // ADR-0019 dedup banner works even if the match below comes back empty (offline).
    if let mid = seedLocation?.mapItemIdentifier { draft.mapItemIdentifier = mid }

    let locationMatch = await placeMatcher.match(page)
    if let match = locationMatch {
      draft.latitude = match.coordinate.latitude
      draft.longitude = match.coordinate.longitude
      // Apple Maps' persistent place identity — the ADR-0019 dedup key. A web page
      // can't carry one, so the match is its only source; but a Maps share already
      // seeded the authoritative identity above, and a coordinate-first match resolves
      // with none — so only adopt the match's when it actually has one.
      if let mid = match.mapItemIdentifier { draft.mapItemIdentifier = mid }
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
    self.detectedEvaluations = await resolveEvaluations(captured.evaluations, page: page)
    await self.refreshExistingMatch()
    await self.loadTrips()
    #if DEBUG
      self.diagnostics = await collectDiagnostics(page: page, refinement: refinement, match: locationMatch)
    #endif
    // Apply explicit tap-to-fill overrides last — user selection wins over the parser.
    if let o = draftOverrides { o.apply(to: &self.draft) }
    self.phase = .ready
  }

  #if DEBUG
    /// Build the match trace for the confirm sheet's DEBUG readout. Re-runs the
    /// *same* search query the matcher used (over the injected `placeSearch`, so it's
    /// the live Apple Maps client on-device and a fixture in tests) and scores each
    /// hit with the very `PlaceMatching.score` gate the matcher applies — so the
    /// readout shows whether a page failed because the search came back empty / threw
    /// (throttle), or because its hits were all scored below the acceptance floor.
    private func collectDiagnostics(
      page: ParsedPage, refinement: PlaceRefinement?, match: LocationMatch?
    ) async -> CaptureDiagnostics {
      let query = PlaceMatching.searchQuery(for: page)
      var threw: String?
      var candidates: [CaptureDiagnostics.ScoredCandidate] = []
      if !query.isEmpty {
        do {
          let hits = try await placeSearch.search(query)
          candidates = hits.map { place in
            CaptureDiagnostics.ScoredCandidate(
              name: place.name,
              address: place.address,
              score: PlaceMatching.score(
                candidateName: place.name,
                candidateStreet: place.address ?? "",
                scrapedName: page.title ?? "",
                scrapedStreet: page.address.oneLine
              ),
              hasIdentifier: place.mapItemIdentifier != nil
            )
          }
        } catch {
          threw = "\(error)"
        }
      }
      return CaptureDiagnostics(
        parsedTitle: page.title,
        titleIsStructured: page.titleIsStructured,
        parsedLocality: page.address.locality,
        parsedRegion: page.address.region,
        parsedAddress: page.address.isEmpty ? nil : page.address.oneLine,
        parsedCoordinate: page.coordinate.map { "\($0.latitude), \($0.longitude)" },
        refinementRan: refinement != nil,
        refinedName: refinement?.name,
        refinedLocality: refinement?.locality,
        refinedRegion: refinement?.region,
        query: query,
        ladder: PlaceMatching.ladder(for: page).map { "\($0)" },
        searchThrew: threw,
        candidates: candidates,
        resolved: match != nil,
        resolvedName: match?.name,
        resolvedHasIdentifier: match?.mapItemIdentifier != nil
      )
    }
  #endif

  /// Look up whether this capture's resolved place is already in the pool (by Apple
  /// Maps identity), so the confirm sheet can offer "update" rather than silently
  /// duplicating (ADR-0019). A no-identity location never matches — nil clears it.
  private func refreshExistingMatch() async {
    guard let mid = draft.mapItemIdentifier else {
      existingMatch = nil
      return
    }
    existingMatch = try? await database.read { db in
      try Idea.where { $0.mapItemIdentifier.eq(mid) }.fetchOne(db)
    }
  }

  /// Turn the page's detected ratings into confirm-sheet rows. Deterministic
  /// recognizers win (`.official`); only when they find nothing does the on-device
  /// LLM extract-only fallback run (`.inferred`) — extraction, never invention
  /// (ADR-0016 §1). Empty when the page carries no recognizable rating.
  private func resolveEvaluations(
    _ recognized: [ParsedEvaluation], page: ParsedPage
  ) async -> [DetectedEvaluation] {
    if !recognized.isEmpty {
      return recognized.map {
        DetectedEvaluation(id: uuid(), parsed: $0, confidence: .official)
      }
    }
    return await evaluationExtractor(page).map {
      DetectedEvaluation(id: uuid(), parsed: $0, confidence: .inferred)
    }
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
    // The chosen place is authoritative for identity too (ADR-0019 dedup key).
    draft.mapItemIdentifier = place.mapItemIdentifier
    if draft.name.isEmpty { draft.name = place.name }
    if draft.kind == nil { draft.kind = place.kind }
    if draft.phone == nil { draft.phone = place.phone }
    if draft.url.isEmpty, let url = place.url { draft.url = url }
    // The picked place may itself already be in the pool — re-check for the banner.
    Task { await refreshExistingMatch() }
  }

  /// Drop the resolved location, leaving it for the user to re-search or fill in
  /// the app later.
  public func clearLocation() {
    draft.latitude = nil
    draft.longitude = nil
    draft.address = nil
    draft.regionName = nil
    // Identity belongs to the resolved place; drop it with the location (ADR-0019).
    draft.mapItemIdentifier = nil
    // No identity → nothing to supplement; clear the banner.
    existingMatch = nil
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
    do {
      // Snapshot the pending record-zone change count *before* the write. In the share
      // extension the engine is stopped, so SQLiteData defers persisting the pending
      // change to a fire-and-forget Task; the host tears the process down the instant
      // we complete the request, which would lose it. After the write we wait until the
      // pending count grows (bounded), guaranteeing the change is durable before the
      // caller calls `completeRequest`. Harmless in-app (running engine → grows
      // synchronously → returns immediately). Best-effort: never blocks the save.
      let pendingBefore = try? await GalavantCloudSync.pendingRecordZoneChangeCount(in: database)
      try await persistCapture()
      if let pendingBefore {
        _ = try? await GalavantCloudSync.waitForPendingRecordZoneChanges(
          in: database, exceeding: pendingBefore
        )
      }
      // Remember the trip so the next capture defaults to the same one.
      if let tripID = selectedTripID { recentTripStore.record(tripID) }
      phase = .saved
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  /// Persist the captured idea + its sibling image and evaluations in one
  /// transaction. Splits the Sendable-scalar marshalling and the write out of
  /// `save()` (the `Idea.Draft` @Table type isn't Sendable, so the draft is rebuilt
  /// inside the closure from captured scalars).
  private func persistCapture() async throws {
    // Hybrid capture (M4f): fetch + shrink just the single best candidate here in
    // the extension (one image stays well inside the ~120 MB budget) so the idea
    // lands with a header image; the full ranked gallery is the app's job (M4g).
    // Best-effort — a missing/undecodable image never blocks the save.
    let headerImage = await prepareHeaderImage()
    let id = draft.id
    let name = draft.name
    let description = draft.description
    let notes = draft.notes
    let kind = draft.kind
    let regionName = draft.regionName
    let address = draft.address
    let phone = draft.phone
    let latitude = draft.latitude
    let longitude = draft.longitude
    let url = draft.url
    let mapItemIdentifier = draft.mapItemIdentifier
    let tripID = selectedTripID
    let imageDisplay = headerImage?.display
    let imageThumbnail = headerImage?.thumbnail
    let imageSourceURL = headerImage?.sourceURL
    let imageID = headerImage?.id
    // Detected ratings Jon kept — written as sibling evaluations in the same
    // transaction as the idea (ADR-0016 §1). `DetectedEvaluation` is Sendable.
    let evaluations = detectedEvaluations.filter(\.included)
    // Opening hours: explicit tap-to-fill override wins over the page parser. Parser
    // result is the fallback for sites with structured JSON-LD/microdata hours; the LLM
    // fallback for unstructured sites runs later in PlaceEnricher
    // (docs/BACKLOG.md "Unstructured-hours capture fallback").
    let openingHoursString = openingHoursDisplay
    // Only consult the clock when something needs stamping (evaluations or hours).
    let stamp = (!evaluations.isEmpty || openingHoursString != nil) ? now.now : Date.distantPast
    try await database.write { db in
      let party = try TravelParty.ensureDefault(in: db)
      let resolved = try Self.resolveIdea(
        in: db, id: id, name: name, description: description, notes: notes, kind: kind,
        regionName: regionName,
        address: address, phone: phone, latitude: latitude, longitude: longitude,
        url: url, mapItemIdentifier: mapItemIdentifier, travelPartyID: party.id,
        openingHours: openingHoursString, hoursProvenance: openingHoursString != nil ? .official : nil,
        hoursVerifiedAt: openingHoursString != nil ? stamp : nil
      )
      guard let targetID = resolved.id else { return }

      // Pull onto the chosen trip (idempotent) so the capture lands as a
      // "considering" entry, not just in the eternal pool.
      if let tripID {
        try TripIdea.pull(ideaID: targetID, into: tripID, in: db)
      }
      // Store the header image alongside the idea, in the same transaction. On a
      // merge, don't force the header — `asHeader` only when this is a brand-new idea,
      // so a re-share never displaces a chosen header (ImageAsset.store de-dups by
      // sourceURL and keeps an existing header otherwise).
      if let imageDisplay, let imageThumbnail, let imageID {
        try ImageAsset.store(
          ideaID: targetID,
          display: imageDisplay,
          thumbnail: imageThumbnail,
          sourceURL: imageSourceURL,
          asHeader: resolved.isNew,
          id: imageID,
          in: db
        )
      }
      // Sibling source evaluations (Michelin ★★★, a Harper 96/100, …). On a re-share
      // `record` de-dups on (source, kind, value), so a supplement adds only new
      // judgments rather than doubling existing ones (ADR-0019 §3).
      try IdeaEvaluation.record(
        evaluations, ideaID: targetID, travelPartyID: party.id, asOf: stamp, in: db
      )
    }
  }

  /// Insert the captured idea, or — when its Apple Maps identity is already in the
  /// pool — supplement that existing idea instead of duplicating it (ADR-0019).
  /// Returns the idea to attach siblings to and whether it was freshly inserted (so
  /// the caller only forces a header image on a brand-new idea). Only a Maps identity
  /// dedups — a geocoded/scraped location (nil id) never auto-merges, so a
  /// name/coordinate guess can't trigger a false merge.
  private nonisolated static func resolveIdea(
    in db: Database,
    id: Idea.ID?,
    name: String,
    description: String,
    notes: String,
    kind: IdeaKind?,
    regionName: String?,
    address: String?,
    phone: String?,
    latitude: Double?,
    longitude: Double?,
    url: String,
    mapItemIdentifier: String?,
    travelPartyID: TravelParty.ID,
    openingHours: String?,
    hoursProvenance: FactProvenance?,
    hoursVerifiedAt: Date?
  ) throws -> (id: Idea.ID?, isNew: Bool) {
    let existing: Idea? = mapItemIdentifier.flatMap { mid in
      try? Idea.where { $0.mapItemIdentifier.eq(mid) }.fetchOne(db)
    }
    if let existing {
      let merged = existing.supplemented(
        name: name, description: description, notes: notes, kind: kind,
        regionName: regionName, address: address,
        phone: phone, latitude: latitude, longitude: longitude, url: url,
        mapItemIdentifier: mapItemIdentifier, openingHours: openingHours,
        hoursProvenance: hoursProvenance, hoursVerifiedAt: hoursVerifiedAt
      )
      // Full-record upsert: `merged` carries every existing column, so this updates
      // the supplemented facts (description fill-blanks, notes appended) without
      // dropping visited/hours/etc.
      try Idea.upsert { Idea.Draft(merged) }.execute(db)
      return (existing.id, false)
    }
    try Idea.insert {
      Idea.Draft(
        id: id,
        name: name,
        description: description,
        notes: notes,
        kind: kind,
        regionName: regionName,
        address: address,
        phone: phone,
        latitude: latitude,
        longitude: longitude,
        url: url,
        openingHours: openingHours,
        hoursProvenance: hoursProvenance,
        hoursVerifiedAt: hoursVerifiedAt,
        mapItemIdentifier: mapItemIdentifier,
        travelPartyID: travelPartyID
      )
    }
    .execute(db)
    return (id, true)
  }
}

#if DEBUG
  /// A read-only trace of one location-match attempt, for the confirm sheet's DEBUG
  /// readout. Captures the inputs the match actually ran on — the parsed page, the
  /// on-device AI refinement, the query, the ladder — and the search outcome (raw
  /// candidates with the matcher's own score, plus whether the search threw). Lets a
  /// failed match be diagnosed on-device without a debugger: an empty `candidates`
  /// with a non-nil `searchThrew` is a throttle/network miss; populated candidates
  /// whose top `score` is 0 is a name-overlap (query) miss, not an Apple Maps miss.
  public struct CaptureDiagnostics: Sendable, Equatable {
    public struct ScoredCandidate: Sendable, Equatable, Identifiable {
      public let id = UUID()
      public var name: String
      public var address: String?
      public var score: Int
      public var hasIdentifier: Bool
    }

    /// What the parser yielded (after the AI refinement merge).
    public var parsedTitle: String?
    public var titleIsStructured: Bool
    public var parsedLocality: String?
    public var parsedRegion: String?
    public var parsedAddress: String?
    public var parsedCoordinate: String?

    /// What the on-device AI refinement returned — the only source of a city token
    /// for a page with no structured address, and so the usual swing factor.
    public var refinementRan: Bool
    public var refinedName: String?
    public var refinedLocality: String?
    public var refinedRegion: String?

    /// The Apple Maps text-search query and the full resolution ladder.
    public var query: String
    public var ladder: [String]

    /// The search probe over `query`: the error description when it threw (throttle /
    /// network — distinct from a genuine empty result), and the scored candidates.
    public var searchThrew: String?
    public var candidates: [ScoredCandidate]

    /// The production match outcome.
    public var resolved: Bool
    public var resolvedName: String?
    public var resolvedHasIdentifier: Bool
  }
#endif
