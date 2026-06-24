import Foundation
import SwiftSoup

/// The web-capture parser engine: one page's HTML → a `ParsedPage`. Pure and
/// best-effort — it never throws and never fetches; a malformed or barren page
/// yields an (often empty) `ParsedPage` the caller can fall back from.
///
/// Layers run least → most structured into a single **value vote** (JSON-LD first,
/// then OpenGraph/Twitter meta, then HTML microdata), so corroboration across
/// layers decides each scalar fact. Images/social/hours accumulate as
/// ordered-unique lists. The same engine serves all three M4 sources (share
/// extension, in-app browser, two-hop fetch); the bytes' origin is irrelevant here.
public enum PageParser {
  /// - Parameters:
  ///   - html: the page source (rendered DOM when available, raw HTML otherwise).
  ///   - sourceURL: the page's URL — used to resolve relative links/images and
  ///     recorded on the result; also the baseline the orchestrator compares
  ///     `websiteURL` against for two-hop enrichment.
  ///   - capturedAt: injected so callers/tests control the "hours rot" timestamp.
  public static func parse(
    html: String,
    sourceURL: URL? = nil,
    capturedAt: Date = Date()
  ) -> ParsedPage {
    var builder = ParseBuilder(sourceURL: sourceURL)
    guard let document = try? SwiftSoup.parse(html, sourceURL?.absoluteString ?? "") else {
      return builder.build(capturedAt: capturedAt)
    }

    JSONLDExtractor.extract(from: document, into: &builder)
    MetaExtractor.extract(from: document, into: &builder)
    MicrodataExtractor.extract(from: document, into: &builder)

    // Harvest body images too — lazy-load `<img>`, srcset/`<picture>`, CSS
    // background images, and `<noscript>` fallbacks — appended after the structured
    // ones (so og:image stays the first/default), enlarging the candidate set the
    // Vision recommender ranks (M4g). Hygiene filtering keeps logos/sprites out.
    BodyImageExtractor.extract(from: document, into: &builder)

    var page = builder.build(capturedAt: capturedAt)
    // Native source judgments (Michelin stars, a Harper score, an embedded aggregate
    // rating) — deterministic recognizers keyed on structure + host (ADR-0016 §1).
    // Run before the boilerplate strip below, which mutates the document.
    page.evaluations = EvaluationRecognizers.recognize(in: document, sourceURL: sourceURL)
    // Plain-text renderings for the on-device models (done last: stripping mutates
    // the document, so it runs after the extractors and image sweep). The parser owns
    // *cleaning*, not model sizing: it emits the full cleaned body, plus a short lead
    // for the summarizer. Whatever a model can actually swallow is the model layer's
    // concern — `OnDeviceModelClient` fits the prompt to its own context window.
    if let cleaned = cleanedBodyText(from: document) {
      page.bodyText = cleaned
      page.textExcerpt = truncate(cleaned, to: summaryLeadLength)
    }
    return page
  }

  /// How much of the page lead the on-device summarizer gets. A deliberate product
  /// budget — a place's description sits up top, so the first ~1500 chars summarize
  /// well without feeding the model the whole site. Not a model limit (that's the
  /// `OnDeviceModelClient`'s context window); the *fact* extractors read the full
  /// `bodyText` instead, since hours/ratings live deep or in a bottom-of-page block.
  private static let summaryLeadLength = 1500

  /// Cleaned, whitespace-collapsed visible text of the page's main content, with
  /// boilerplate removed. `nil` when nothing meaningful remains.
  ///
  /// Boilerplate is stripped two ways, because many real sites ship no semantic
  /// landmarks (das-achental.com renders its whole menu as `<ul><li><a>` with **no**
  /// `<nav>`/`<header>`): semantic tags plus a few unambiguous chrome classes
  /// (cookie/consent/breadcrumb) first, then by **link density** — a block whose
  /// visible text is mostly link text is navigation, not prose. The link-density pass
  /// is what catches a class-less nav; we deliberately *don't* strip `class*=menu`,
  /// since on a restaurant site that's the food menu — real content, and link-density
  /// already removes the actual navigation. Without it a chrome-heavy menu fills the
  /// budget and the real content (including hours) never reaches the model.
  private static func cleanedBodyText(from document: Document) -> String? {
    for selector in [
      "script", "style", "noscript", "nav", "header", "footer", "aside",
      "[class*=cookie]", "[class*=consent]", "[class*=breadcrumb]",
    ] {
      _ = try? document.select(selector).remove()
    }
    removeLinkDenseBlocks(in: document)
    guard let raw = try? document.body()?.text(), !raw.isEmpty else { return nil }
    let collapsed = raw.components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    return collapsed.isEmpty ? nil : collapsed
  }

  /// Remove list/container blocks whose visible text is dominated by link text — the
  /// readability signal for a nav menu or link farm that carries no real content.
  /// Outermost match wins (removing a parent takes its children), and a block needs a
  /// handful of links before it qualifies, so a single in-prose link is never culled.
  private static func removeLinkDenseBlocks(in document: Document) {
    guard let candidates = try? document.select("ul, ol, div") else { return }
    for element in candidates.array() {
      // Skip if an ancestor already got removed this pass (no parent ⇒ detached).
      guard element.parent() != nil else { continue }
      guard
        let links = try? element.select("a"), links.size() >= 4,
        let total = try? element.text(), !total.isEmpty
      else { continue }
      let linkText = links.array().compactMap { try? $0.text() }.joined()
      if Double(linkText.count) / Double(total.count) > 0.6 {
        try? element.remove()
      }
    }
  }

  /// Truncate to a budget on a word boundary so we never cut a word in half.
  private static func truncate(_ text: String, to limit: Int) -> String {
    guard text.count > limit else { return text }
    let clipped = text.prefix(limit)
    if let lastSpace = clipped.lastIndex(of: " ") {
      return String(clipped[..<lastSpace])
    }
    return String(clipped)
  }
}
