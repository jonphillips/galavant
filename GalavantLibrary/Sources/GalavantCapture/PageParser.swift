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
    // A plain-text excerpt for the on-device summarizer (done last: it strips
    // boilerplate from the document, after the extractors and image sweep have run).
    page.textExcerpt = textExcerpt(from: document)
    return page
  }

  /// The maximum excerpt length handed to the summarizer — enough to describe the
  /// place, bounded to keep the share extension's model latency/memory in check.
  private static let maxExcerptLength = 1500

  /// Cleaned, truncated visible text of the page's main content. Strips obvious
  /// boilerplate (script/style/nav/header/footer/aside), collapses whitespace, and
  /// truncates on a word boundary. Best-effort — `nil` when nothing meaningful.
  private static func textExcerpt(from document: Document) -> String? {
    for selector in ["script", "style", "noscript", "nav", "header", "footer", "aside"] {
      _ = try? document.select(selector).remove()
    }
    guard let raw = try? document.body()?.text(), !raw.isEmpty else { return nil }
    let collapsed = raw.components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    guard !collapsed.isEmpty else { return nil }
    guard collapsed.count > maxExcerptLength else { return collapsed }
    let clipped = collapsed.prefix(maxExcerptLength)
    // Back up to the last space so we don't cut a word in half.
    if let lastSpace = clipped.lastIndex(of: " ") {
      return String(clipped[..<lastSpace])
    }
    return String(clipped)
  }
}
