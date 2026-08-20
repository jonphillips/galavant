import Dependencies
import Foundation
import GalavantCapture
import GalavantSchema
import SQLiteData

/// MapKit's opening-hours probe — **rung 1** of the supplement ladder (ADR-0016 §2).
/// As of iOS 27 `MKMapItem` exposes name / phone / url / address but **no business
/// hours** (verified against the Xcode-beta SDK headers — `apple-sdk-headers-
/// authoritative`), so the live probe returns `nil`: the rung is a seam, ready to
/// light up the day Apple ships the API, with no call-site change. Injectable like
/// the rest so the ladder is testable.
public struct MapItemHoursProbe: Sendable {
  var probe: @Sendable (_ latitude: Double, _ longitude: Double, _ name: String) async -> String?

  public init(
    probe: @escaping @Sendable (_ latitude: Double, _ longitude: Double, _ name: String) async -> String?
  ) {
    self.probe = probe
  }

  public func callAsFunction(_ latitude: Double, _ longitude: Double, _ name: String) async -> String? {
    await probe(latitude, longitude, name)
  }
}

extension MapItemHoursProbe: DependencyKey {
  /// No opening-hours API on `MKMapItem` (iOS 27 SDK) — the rung exists but yields
  /// nothing today. The ladder falls through to the official-site fetch.
  public static let liveValue = MapItemHoursProbe { _, _, _ in nil }
  public static let testValue = MapItemHoursProbe { _, _, _ in nil }
}

extension DependencyValues {
  public var mapItemHoursProbe: MapItemHoursProbe {
    get { self[MapItemHoursProbe.self] }
    set { self[MapItemHoursProbe.self] = newValue }
  }
}

/// On-demand opening-hours supplement (ADR-0016 §2): fill an idea's *factual* hours
/// from the cheapest source that can, on a tap. The ladder, each rung an injectable
/// client (`inject-io-boundaries-early`):
///
/// 1. **MapKit** (`mapItemHoursProbe`) — no hours API on iOS 27; a no-op seam.
/// 2. **The place's own site** — fetch `Idea.url` (reusing M4g's `PageFetcher`) and
///    re-parse. First the deterministic `ParsedPage.openingHours` (JSON-LD/microdata);
///    then, when that's empty, an on-device **LLM extract-only** pass over the same
///    page text (`hoursExtractor`) reaches the unstructured-markup sites the parser
///    can't (Squarespace/Wix; docs/BACKLOG.md). When the cheap GET yields no hours, a
///    headless WebKit **rendered-DOM** re-fetch (`renderedPageFetcher`, ADR-0024) runs
///    once more for JS-injected hours. Either way the source is the place's own site,
///    so provenance `.official`.
/// 3. **HITL `WKWebView`** — the app's interactive fallback when 1–2 come up empty;
///    it hands the loaded DOM to `applyBrowsedHours` (deterministic then the same LLM
///    fallback; provenance `.unverified` — an arbitrary page the user drove).
///
/// Hours land on **`Idea`** (facts), never `IdeaEvaluation` (judgments) — the
/// load-bearing split. Lives in the package so the network-free path is the tested
/// default (the live probe + a fixture `PageFetcher`).
@MainActor
public final class FieldSupplement {
  @Dependency(\.defaultDatabase) private var database
  @Dependency(\.pageFetcher) private var pageFetcher
  @Dependency(\.renderedPageFetcher) private var renderedPageFetcher
  @Dependency(\.mapItemHoursProbe) private var hoursProbe
  @Dependency(\.hoursExtractor) private var hoursExtractor
  @Dependency(\.date) private var now

  /// What a supplement attempt did — drives the affordance's feedback.
  public enum Outcome: Equatable, Sendable {
    /// Hours were filled from a rung, stamped with this provenance.
    case filled(FactProvenance)
    /// No rung could fill them — the app offers the HITL browser next.
    case notFound
    /// The idea already had hours and `force` wasn't set.
    case alreadyPresent
  }

  public init() {}

  /// Climb the cheapest-first ladder to fill an idea's opening hours. A no-op (and
  /// `.alreadyPresent`) when the idea already has hours unless `force` is set.
  @discardableResult
  public func supplementHours(ideaID: Idea.ID, force: Bool = false) async -> Outcome {
    guard let idea = try? await database.read({ db in try Idea.find(ideaID).fetchOne(db) })
    else { return .notFound }
    if idea.openingHours != nil, !force { return .alreadyPresent }

    // Rung 1: MapKit (no hours on iOS 27 — yields nil today; see MapItemHoursProbe).
    if let latitude = idea.latitude, let longitude = idea.longitude,
      let hours = await hoursProbe(latitude, longitude, idea.name).flatMap(Self.cleaned)
    {
      await write(hours, provenance: .official, ideaID: ideaID)
      return .filled(.official)
    }

    // Rung 2: the place's own official site — fetch + parse, then try the deterministic
    // hours and, failing that, the on-device LLM extract-only pass over the page text.
    // Render-on-miss (ADR-0024): the cheap `URLSession` GET first; only if *that* yields
    // no hours do we re-fetch with a headless WebKit render — a page can parse rich yet
    // inject its hours via JS, and the rendered DOM carries the text both the parser and
    // the LLM need. Either source is the place's own site → `.official`.
    if !idea.url.isEmpty, let url = URL(string: idea.url) {
      var hours = await hoursFromSite(url, fetch: pageFetcher.callAsFunction)
      if hours == nil { hours = await hoursFromSite(url, fetch: renderedPageFetcher.callAsFunction) }
      if let hours {
        await write(hours, provenance: .official, ideaID: ideaID)
        return .filled(.official)
      }
    }

    return .notFound  // rung 3 (the HITL browser) is the app's fallback
  }

  /// Rung 3 write-back: hours grabbed from the DOM the user loaded in the in-app
  /// browser — the deterministic parser first, then the same on-device LLM fallback
  /// for unstructured-markup pages. Provenance `.unverified` — it came through a page
  /// the user drove, not an authoritative source. Returns whether any hours were found.
  @discardableResult
  public func applyBrowsedHours(html: String, sourceURL: URL?, ideaID: Idea.ID) async -> Bool {
    let page = PageParser.parse(html: html, sourceURL: sourceURL)
    guard let hours = await resolvedHours(from: page) else { return false }
    await write(hours, provenance: .unverified, ideaID: ideaID)
    return true
  }

  /// Fetch the site with `fetch`, parse it against the fetch's effective URL, and
  /// resolve hours — `nil` when the fetch failed or the page carried none. The unit a
  /// render-on-miss escalation retries with a heavier fetcher (ADR-0024).
  private func hoursFromSite(
    _ url: URL, fetch: (URL) async -> FetchedDocument?
  ) async -> String? {
    guard let document = await fetch(url) else { return nil }
    return await resolvedHours(
      from: PageParser.parse(html: document.html, sourceURL: document.effectiveURL)
    )
  }

  /// Hours from an already-parsed page: the deterministic `openingHours` first, and
  /// only when that's empty the on-device LLM extract-only pass (the unstructured-
  /// markup fallback — Squarespace/Wix; docs/BACKLOG.md). So a structured page never
  /// pays for a model call. `nil` when neither yields hours.
  private func resolvedHours(from page: ParsedPage) async -> String? {
    if let deterministic = Self.hours(from: page) { return deterministic }
    return (await hoursExtractor(page)).flatMap(Self.cleaned)
  }

  /// The deterministic opening-hours block from an already-parsed page — the capture
  /// parser already mines `openingHours` (JSON-LD/microdata). `nil` when it found none.
  static func hours(from page: ParsedPage) -> String? {
    page.openingHours.isEmpty ? nil : page.openingHours.joined(separator: "\n")
  }

  private static func cleaned(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func write(_ hours: String, provenance: FactProvenance, ideaID: Idea.ID) async {
    let stamp = now.now
    try? await database.write { db in
      try Idea.setOpeningHours(
        ideaID: ideaID, hours: hours, provenance: provenance, verifiedAt: stamp, in: db
      )
    }
  }
}
