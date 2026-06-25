import Dependencies
import Foundation
import GalavantCapture
import GalavantImaging
import GalavantSchema
import SQLiteData

/// The app-side **second enrichment hop** (M4g): once an idea is in the pool, fetch
/// its own website (the `url` the capture preserved — usually richer than the
/// originally shared page, which is often an aggregator), re-parse it, backfill any
/// blank facts via Apple Intelligence, and download + Vision-rank its images into a
/// gallery. Runs **once** per idea, gated on `Idea.enrichedAt`, and is entirely
/// best-effort — a failed hop leaves the idea exactly as captured.
///
/// Lives in the package (not the app) so the orchestration is testable with fixture
/// fetchers, recommender, and an in-memory DB — the deterministic, network-free path
/// is the tested default (every injected client has a no-op/flat `testValue`).
@MainActor
public final class PlaceEnricher {
  @Dependency(\.defaultDatabase) private var database
  @Dependency(\.pageFetcher) private var pageFetcher
  @Dependency(\.renderedPageFetcher) private var renderedPageFetcher
  @Dependency(\.imageFetcher) private var imageFetcher
  @Dependency(\.imageRecommender) private var imageRecommender
  @Dependency(\.placeIntelligence) private var placeIntelligence
  @Dependency(\.hoursExtractor) private var hoursExtractor
  @Dependency(\.uuid) private var uuid
  @Dependency(\.date) private var now

  /// Cap on candidate images fetched + stored per idea — bounds network, Vision
  /// work, and synced bytes.
  static let maxImages = 6

  public init() {}

  /// Enrich one idea if it hasn't been already. No-op when the idea is missing,
  /// already enriched, or has no usable website URL. Stamps `enrichedAt` only on a
  /// successful hop so a transient fetch failure can be retried later.
  public func enrichIfNeeded(ideaID: Idea.ID) async {
    guard
      let idea = try? await database.read({ db in try Idea.find(ideaID).fetchOne(db) }),
      idea.enrichedAt == nil,
      !idea.url.isEmpty,
      let url = URL(string: idea.url),
      var page = await parsedPage(at: url)
    else { return }

    if let refinement = await placeIntelligence(page) {
      page = page.applying(refinement)
    }

    // Follow at most one guide-detail link the page points at (ADR-0021), folding its
    // rating + any blank facts back in before the single write below.
    page = await followingGuideLink(from: page)

    // Source judgments the parse/merge surfaced (the guide ★★★, an embedded aggregate
    // rating) become `IdeaEvaluation`s — deterministic recognizers, so `.official`.
    // Needs the owning party; idempotent on (source, kind, value), ADR-0019 §3.
    let detections =
      idea.travelPartyID == nil
      ? []
      : page.evaluations.map { DetectedEvaluation(id: uuid(), parsed: $0, confidence: .official) }

    let images = await rankedImages(page.imageURLs)

    // Backfill only fields the capture left blank (confirm-and-tweak — never clobber
    // a fact the user or the original capture already established). Pre-resolved to
    // final values so the update is straight assignment (a no-op where already set).
    let notes = idea.notes.isEmpty ? (TextCleaning.demarketed(page.summary) ?? idea.notes) : idea.notes
    let regionName = idea.regionName ?? page.address.locality ?? page.address.region
    let phone = idea.phone ?? page.phone
    let pageAddress = page.address.oneLine
    let address = idea.address ?? (pageAddress.isEmpty ? nil : pageAddress)
    let kind = idea.kind ?? IdeaKind(schemaOrgTypes: page.schemaTypes)

    let resolvedHours = idea.openingHours == nil ? await hoursIfAbsent(page: page) : nil
    let stamp = now.now

    try? await database.write { db -> Void in
      try Idea.find(ideaID)
        .update {
          $0.notes = #bind(notes)
          $0.regionName = #bind(regionName)
          $0.phone = #bind(phone)
          $0.address = #bind(address)
          $0.kind = #bind(kind)
          $0.enrichedAt = #bind(stamp)
        }
        .execute(db)
      if let resolvedHours {
        try Idea.setOpeningHours(
          ideaID: ideaID, hours: resolvedHours, provenance: .official,
          verifiedAt: stamp, in: db
        )
      }
      if let travelPartyID = idea.travelPartyID, !detections.isEmpty {
        try IdeaEvaluation.record(
          detections, ideaID: ideaID, travelPartyID: travelPartyID, asOf: stamp, in: db
        )
      }
      try storeRankedImages(images, forIdea: ideaID, in: db)
    }
  }

  /// Store the ranked candidates (idempotent on sourceURL — the M4f header re-stores
  /// cleanly), then make the top-ranked one the header. Enrichment runs once, so a later
  /// manual pick (M4h gallery) won't be clobbered.
  nonisolated private func storeRankedImages(
    _ images: [RankedImage], forIdea ideaID: Idea.ID, in db: Database
  ) throws {
    var headerID: ImageAsset.ID?
    for image in images {
      let stored = try ImageAsset.store(
        ideaID: ideaID,
        display: image.display,
        thumbnail: image.thumbnail,
        sourceURL: image.sourceURL,
        id: image.id,
        in: db
      )
      if headerID == nil { headerID = stored.id }
    }
    if let headerID {
      try ImageAsset.setHeader(headerID, ideaID: ideaID, in: db)
    }
  }

  /// Follow at most one recognized guide-detail link on the page and fold its parse
  /// (rating + blank facts) back in (ADR-0021). Bounded and best-effort: one link only,
  /// and a no-op when nothing qualifies or the fetch fails. We deliberately *don't*
  /// skip on "the idea already has a judgment from this guide" — that guard was
  /// source-coarse and suppressed a genuinely-new *kind* (e.g. an idea carrying a
  /// Michelin Green Star would never collect its ★★★). Re-following is cheap and safe:
  /// the hop runs once per idea (the `enrichedAt` gate), and the rating rides
  /// `IdeaEvaluation.record`'s (source, kind, value) idempotency (ADR-0019 §3), so a
  /// place already carrying the exact rating isn't doubled. The guide page is parsed
  /// with its own URL as `sourceURL`, so the host recognizers fire (host = guide → ★★★).
  private func followingGuideLink(from page: ParsedPage) async -> ParsedPage {
    guard let link = GuideLinkRecognizer.recognize(in: page).first,
      let guidePage = await parsedPage(at: link.url)
    else { return page }
    return page.fillingBlanks(from: guidePage)
  }

  /// Fetch and parse a page, escalating to a headless WebKit **rendered-DOM** re-fetch
  /// when the cheap `URLSession` GET parses to nothing (render-on-miss, ADR-0024) — the
  /// JS-shell / SPA / anti-bot pages where a raw fetch returns an empty container. Returns
  /// the richest parse obtained; `nil` only when *no* fetch returned anything (a true
  /// failure — leave the idea unenriched so the `enrichedAt` gate lets it retry). A page
  /// that fetches but parses empty is still returned, preserving the "fetched once → done"
  /// gate semantics.
  private func parsedPage(at url: URL) async -> ParsedPage? {
    let staticPage = await pageFetcher(url).map { PageParser.parse(html: $0, sourceURL: url) }
    if let staticPage, !staticPage.isEmpty { return staticPage }
    if let rendered = await renderedPageFetcher(url) {
      let renderedPage = PageParser.parse(html: rendered, sourceURL: url)
      if !renderedPage.isEmpty { return renderedPage }
    }
    return staticPage  // nil iff the static fetch also failed → retry later
  }

  /// Opening hours from an already-parsed page when the idea has none yet:
  /// deterministic JSON-LD/microdata first, then the on-device LLM extract-only pass
  /// for unstructured-markup sites (Squarespace/Wix; docs/BACKLOG.md). Mirrors the
  /// FieldSupplement.resolvedHours helper. `nil` when neither yields anything.
  private func hoursIfAbsent(page: ParsedPage) async -> String? {
    if let deterministic = FieldSupplement.hours(from: page) { return deterministic }
    guard let extracted = await hoursExtractor(page) else { return nil }
    let trimmed = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// A processed image ready to store, in recommended (best-first) order.
  private struct RankedImage {
    var sourceURL: String
    var display: Data
    var thumbnail: Data
    var id: UUID
  }

  /// Download, score, and process the candidates: best photo first, utility images
  /// (logos/screenshots) sunk by the recommender, parser order preserved on ties.
  private func rankedImages(_ candidates: [URL]) async -> [RankedImage] {
    var scored: [(index: Int, url: URL, data: Data, score: Double)] = []
    for (index, candidate) in candidates.prefix(Self.maxImages).enumerated() {
      guard let data = await imageFetcher(candidate) else { continue }
      let score = await imageRecommender(data)
      scored.append((index, candidate, data, score))
    }
    return
      scored
      .sorted { $0.score == $1.score ? $0.index < $1.index : $0.score > $1.score }
      .compactMap { item in
        guard let processed = ImageProcessing.process(item.data) else { return nil }
        return RankedImage(
          sourceURL: item.url.absoluteString,
          display: processed.display,
          thumbnail: processed.thumbnail,
          id: uuid()
        )
      }
  }
}
