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

    // Last resort only (scraping-enrichment.md): if no structured image surfaced,
    // sweep body images through the same hygiene filter rather than leaving the
    // capture pictureless.
    if builder.images.isEmpty {
      for img in (try? document.select("img[src]").array()) ?? [] {
        builder.addImage(try? img.absUrl("src"))
      }
    }

    return builder.build(capturedAt: capturedAt)
  }
}
