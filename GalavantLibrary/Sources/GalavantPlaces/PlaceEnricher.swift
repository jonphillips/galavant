import Dependencies
import Foundation
import GalavantCapture
import GalavantImaging
import GalavantSchema
import ImageIO
import SQLiteData

/// The result of an explicit image refresh, preserving the reason an image gallery
/// did or did not change so the form can explain the outcome.
public enum ImageRefreshOutcome: Equatable, Sendable {
  case refreshed(storedCount: Int)
  case pageUnavailable
  case noCandidates
  case noneUsable
  case storageFailed
}

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
  /// Hard ceiling on candidate URLs fetched before size filtering and ranking.
  static let maxImageCandidates = 20

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
    // The page descriptor backfills `description` (a fact), not `notes` — notes is the
    // user's own space (ADR-0026), never touched by enrichment.
    let description = idea.description.isEmpty
      ? (TextCleaning.demarketed(page.summary) ?? idea.description) : idea.description
    let regionName = idea.regionName ?? page.address.locality ?? page.address.region
    let phone = idea.phone ?? page.phone
    let pageAddress = page.address.oneLine
    let address = idea.address ?? (pageAddress.isEmpty ? nil : pageAddress)
    let kind = idea.kind ?? IdeaKind(schemaOrgTypes: page.schemaTypes)

    // Hours are fill-blanks-only and frozen by a `.manual` stamp (ADR-0016/0029): the
    // free-form string and structured hours share one `hoursProvenance`, so a manual
    // edit to either wins over re-enrichment of both.
    let hoursAreManual = idea.hoursProvenance == .manual
    let resolvedHours =
      idea.openingHours == nil && !hoursAreManual ? await hoursIfAbsent(page: page) : nil
    // Structured weekday hours (ADR-0029). Independent of the string above — a page can
    // carry structured markup but no string we didn't already have, or vice versa.
    let resolvedStructured =
      idea.structuredHours == nil && !hoursAreManual
      ? await structuredHoursIfAbsent(page: page) : nil
    let stamp = now.now

    try? await database.write { db -> Void in
      try Idea.find(ideaID)
        .update {
          $0.description = #bind(description)
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
      if let resolvedStructured {
        try Idea.setStructuredHours(
          ideaID: ideaID, hours: resolvedStructured, provenance: .official,
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

  /// Re-fetch and replace/augment an idea's scraped image gallery on explicit user
  /// request. Unlike `enrichIfNeeded`, this intentionally ignores `enrichedAt`; it
  /// only refreshes images and never changes the idea's hand-edited facts.
  @discardableResult
  public func refetchImages(ideaID: Idea.ID) async -> ImageRefreshOutcome {
    guard
      let idea = try? await database.read({ db in try Idea.find(ideaID).fetchOne(db) }),
      !idea.url.isEmpty,
      let url = URL(string: idea.url),
      let page = await parsedPage(at: url, isMiss: { $0.imageURLs.isEmpty })
    else { return .pageUnavailable }

    guard !page.imageURLs.isEmpty else { return .noCandidates }
    let images = await rankedImages(page.imageURLs)
    guard !images.isEmpty else { return .noneUsable }

    do {
      try await database.write { db in
        try storeRankedImages(images, forIdea: ideaID, in: db)
      }
      return .refreshed(storedCount: images.count)
    } catch {
      return .storageFailed
    }
  }

  /// Store the ranked candidates (idempotent on sourceURL — the M4f header re-stores
  /// cleanly), then make the top-ranked one the header only when this idea did not
  /// already have one. That preserves a later manual pick (M4h gallery) during an
  /// explicit image refetch.
  nonisolated private func storeRankedImages(
    _ images: [RankedImage], forIdea ideaID: Idea.ID, in db: Database
  ) throws {
    let alreadyHasHeader = try ImageAsset.images(forIdea: ideaID, in: db).contains(where: \.isHeader)
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
    if !alreadyHasHeader, let headerID {
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
  /// when the cheap `URLSession` GET matches the caller's miss predicate (render-on-miss,
  /// ADR-0024). Every parse uses that fetch's effective URL as the relative-value base.
  /// A rendered hit is merged into the static page so useful static facts survive. Returns
  /// `nil` only when no fetch returned anything (a true failure — leave the idea
  /// unenriched so the `enrichedAt` gate lets it retry).
  private func parsedPage(
    at url: URL,
    isMiss: (ParsedPage) -> Bool = { $0.isEmpty }
  ) async -> ParsedPage? {
    let staticPage = await pageFetcher(url).map {
      PageParser.parse(html: $0.html, sourceURL: $0.effectiveURL)
    }
    guard let staticPage else {
      guard let rendered = await renderedPageFetcher(url) else { return nil }
      return PageParser.parse(html: rendered.html, sourceURL: rendered.effectiveURL)
    }
    guard isMiss(staticPage) else { return staticPage }
    guard let rendered = await renderedPageFetcher(url) else { return staticPage }
    let renderedPage = PageParser.parse(html: rendered.html, sourceURL: rendered.effectiveURL)
    return staticPage.fillingBlanks(from: renderedPage)
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

  /// Structured weekday hours (ADR-0029) from an already-parsed page when the idea
  /// has none: deterministic schema.org-token parse first, then the on-device LLM
  /// structuring pass for unstructured-markup sites (mirrors `hoursIfAbsent`). `nil`
  /// when neither yields an assertion.
  private func structuredHoursIfAbsent(page: ParsedPage) async -> WeeklyHours? {
    if let deterministic = WeeklyHoursParser.parse(page.openingHours) { return deterministic }
    return await hoursExtractor.structured(page)
  }

  /// A processed image ready to store, in recommended (best-first) order.
  private struct RankedImage {
    var sourceURL: String
    var display: Data
    var thumbnail: Data
    var id: UUID
  }

  /// Download, size-filter, score, and process the candidates: best photo first,
  /// utility images (logos/screenshots) excluded or sunk, parser order preserved on
  /// ties. Only the final `maxImages` candidates are fully processed and stored.
  private func rankedImages(_ candidates: [URL]) async -> [RankedImage] {
    var fetched: [
      (candidate: ImageRankingCandidate, url: URL, data: Data)
    ] = []
    for (index, candidate) in candidates.prefix(Self.maxImageCandidates).enumerated() {
      guard let data = await imageFetcher(candidate) else { continue }
      guard let dimensions = Self.imageDimensions(in: data) else { continue }
      guard max(dimensions.width, dimensions.height) >= ImageRanking.minimumLongestEdge else {
        continue
      }
      let score = await imageRecommender(data)
      fetched.append(
        (
          candidate: ImageRankingCandidate(
            index: index,
            visionScore: score,
            width: dimensions.width,
            height: dimensions.height
          ),
          url: candidate,
          data: data
        )
      )
    }

    let ranked = ImageRanking.ordered(fetched.map(\.candidate))
    return
      ranked.prefix(Self.maxImages)
      .compactMap { item in
        guard
          let fetched = fetched.first(where: { $0.candidate.index == item.index }),
          let processed = ImageProcessing.process(fetched.data)
        else { return nil }
        return RankedImage(
          sourceURL: fetched.url.absoluteString,
          display: processed.display,
          thumbnail: processed.thumbnail,
          id: uuid()
        )
      }
  }

  /// Reads encoded pixel dimensions from ImageIO metadata without decoding the
  /// image. This keeps the size filter cheap before the final display processing.
  private nonisolated static func imageDimensions(in data: Data) -> (width: Int, height: Int)? {
    guard
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      width > 0,
      height > 0
    else { return nil }
    return (width, height)
  }
}
