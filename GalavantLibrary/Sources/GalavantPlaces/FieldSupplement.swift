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
///    re-parse; `ParsedPage.openingHours` is already extracted. Provenance `.official`.
/// 3. **HITL `WKWebView`** — the app's interactive fallback when 1–2 come up empty;
///    it hands the loaded DOM to `applyBrowsedHours` (provenance `.unverified`).
///
/// Hours land on **`Idea`** (facts), never `IdeaEvaluation` (judgments) — the
/// load-bearing split. Lives in the package so the network-free path is the tested
/// default (the live probe + a fixture `PageFetcher`).
@MainActor
public final class FieldSupplement {
  @Dependency(\.defaultDatabase) private var database
  @Dependency(\.pageFetcher) private var pageFetcher
  @Dependency(\.mapItemHoursProbe) private var hoursProbe
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

    // Rung 2: the place's own official site.
    if !idea.url.isEmpty, let url = URL(string: idea.url),
      let html = await pageFetcher(url),
      let hours = Self.hours(fromHTML: html, sourceURL: url)
    {
      await write(hours, provenance: .official, ideaID: ideaID)
      return .filled(.official)
    }

    return .notFound  // rung 3 (the HITL browser) is the app's fallback
  }

  /// Rung 3 write-back: hours grabbed from the DOM the user loaded in the in-app
  /// browser. Provenance `.unverified` — it came through a page the user drove, not
  /// an authoritative source. Returns whether the DOM yielded any hours.
  @discardableResult
  public func applyBrowsedHours(html: String, sourceURL: URL?, ideaID: Idea.ID) async -> Bool {
    guard let hours = Self.hours(fromHTML: html, sourceURL: sourceURL) else { return false }
    await write(hours, provenance: .unverified, ideaID: ideaID)
    return true
  }

  /// Parse an opening-hours block out of a page's DOM/HTML — reuses the capture
  /// parser, which already mines `openingHours`. `nil` when the page states none.
  static func hours(fromHTML html: String, sourceURL: URL?) -> String? {
    let page = PageParser.parse(html: html, sourceURL: sourceURL)
    return page.openingHours.isEmpty ? nil : page.openingHours.joined(separator: "\n")
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
