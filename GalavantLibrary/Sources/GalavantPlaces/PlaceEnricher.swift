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
      let html = await pageFetcher(url)
    else { return }

    var page = PageParser.parse(html: html, sourceURL: url)
    if let refinement = await placeIntelligence(page) {
      page = page.applying(refinement)
    }

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

      // Store the ranked candidates (idempotent on sourceURL — the M4f header
      // re-stores cleanly), then make the top-ranked one the header. Enrichment runs
      // once, so a later manual pick (M4h gallery) won't be clobbered.
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
