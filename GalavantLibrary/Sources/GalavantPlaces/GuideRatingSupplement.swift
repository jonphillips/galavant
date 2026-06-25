import Dependencies
import Foundation
import GalavantCapture
import GalavantSchema
import SQLiteData

/// On-demand **guide-rating** supplement (ADR-0023) — the human-in-the-loop fallback to
/// ADR-0021's automated guide-link hop. Where the enricher's plain `URLSession` fetch of
/// a recognized guide-detail link comes back empty on a JS-heavy / consent-walled /
/// anti-bot page, this drives the same recognition over a page the user renders in the
/// in-app browser, and records the rating it carries.
///
/// The judgments-sibling of `FieldSupplement`: that one owns *facts* (hours, onto `Idea`)
/// and never writes `IdeaEvaluation`; this one owns the *judgment* (a guide's rating,
/// onto `IdeaEvaluation`) and never touches `Idea`'s facts. Same two-method shape —
/// `supplement` (the cheap rung, re-run on demand) and `applyBrowsedGuide` (the rung-3
/// write-back from the rendered DOM) — so the form affordance mirrors "Find Hours".
///
/// Lives in the package so the network-free path is the tested default (a fixture
/// `pageFetcher` + an in-memory DB), like the capture and hours flows.
@MainActor
public final class GuideRatingSupplement {
  @Dependency(\.defaultDatabase) private var database
  @Dependency(\.pageFetcher) private var pageFetcher
  @Dependency(\.uuid) private var uuid
  @Dependency(\.date) private var now

  /// What a guide-rating attempt did — drives the affordance's feedback.
  public enum Outcome: Equatable, Sendable {
    /// The cheap rung already rendered: `count` *new* ratings were recorded (0 means a
    /// guide page was read but the idea already carried everything on it).
    case recorded(Int)
    /// A guide-detail link was found but its plain fetch yielded no rating (the JS-heavy
    /// case) — the app opens the in-app browser at `url` so the user can render it.
    case needsBrowser(URL)
    /// The idea's page points at no recognized guide-detail link — nothing to follow.
    case noGuideLink
    /// The idea can't be supplemented: missing, no link to start from, or no owning
    /// travel party to attribute the rating to (`IdeaEvaluation` requires one).
    case notReady
  }

  public init() {}

  /// Re-run the automated guide-link rung on demand. Fetch the idea's own page, find the
  /// first recognized guide-detail link (ADR-0021), fetch **that** link, and record any
  /// rating it carries. When the link's plain fetch comes back without a rating — the
  /// page that needs a real browser — return `.needsBrowser(guideURL)` so the form can
  /// open the in-app browser pointed straight at it.
  public func supplement(ideaID: Idea.ID) async -> Outcome {
    guard let idea = try? await database.read({ db in try Idea.find(ideaID).fetchOne(db) }),
      let travelPartyID = idea.travelPartyID,
      !idea.url.isEmpty, let url = URL(string: idea.url)
    else { return .notReady }

    // Find the guide-detail link the idea's own page points at (the same recognizer the
    // enricher uses). No fetch of the idea page → nothing to follow.
    guard let html = await pageFetcher(url),
      let link = GuideLinkRecognizer.recognize(in: PageParser.parse(html: html, sourceURL: url)).first
    else { return .noGuideLink }

    // Plain-fetch the guide page (the rung that already ran during enrichment). If it
    // renders, record what it says; if not, hand the user the browser at this URL.
    guard let guideHTML = await pageFetcher(link.url) else { return .needsBrowser(link.url) }
    let recorded = await record(
      PageParser.parse(html: guideHTML, sourceURL: link.url), ideaID: ideaID,
      travelPartyID: travelPartyID
    )
    return recorded == nil ? .needsBrowser(link.url) : .recorded(recorded ?? 0)
  }

  /// Rung-3 write-back: record the rating off the DOM the user rendered in the in-app
  /// browser. Parsed with the page's own URL as `sourceURL`, so the host
  /// `EvaluationRecognizers` fire (host = guide → ★★★). Returns the count of *new*
  /// ratings recorded; `nil` when the page carried none or the idea isn't ready.
  @discardableResult
  public func applyBrowsedGuide(html: String, sourceURL: URL?, ideaID: Idea.ID) async -> Int? {
    guard let idea = try? await database.read({ db in try Idea.find(ideaID).fetchOne(db) }),
      let travelPartyID = idea.travelPartyID
    else { return nil }
    return await record(
      PageParser.parse(html: html, sourceURL: sourceURL), ideaID: ideaID,
      travelPartyID: travelPartyID
    )
  }

  /// Map a parsed page's evaluations to `.official` detections and record them
  /// (idempotent on the (source, kind, value) triad, ADR-0019 §3). `.official` — a
  /// deterministic host recognizer read the guide's own page, the same rung the
  /// automated hop stamps `.official`; rendering it in a browser doesn't make it less
  /// authoritative (ADR-0023). Returns the count newly recorded, or `nil` when the page
  /// carried no rating at all (so the caller can distinguish "nothing here" from "all
  /// already known").
  private func record(
    _ page: ParsedPage, ideaID: Idea.ID, travelPartyID: TravelParty.ID
  ) async -> Int? {
    guard !page.evaluations.isEmpty else { return nil }
    let detections = page.evaluations.map {
      DetectedEvaluation(id: uuid(), parsed: $0, confidence: .official)
    }
    let stamp = now.now
    return try? await database.write { db in
      try IdeaEvaluation.record(
        detections, ideaID: ideaID, travelPartyID: travelPartyID, asOf: stamp, in: db
      )
    }
  }
}
