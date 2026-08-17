import Foundation
import SwiftSoup

/// Harvests images the structured layers miss: lazy-loaded `<img>` (the real `src`
/// hidden behind `data-*`), responsive `srcset` / `<picture><source>`, CSS
/// `background-image` (inline styles, `<style>` blocks, and `data-bg`-style hooks —
/// where hero photos so often live), and `<noscript>` fallbacks. Every candidate
/// goes through `builder.addImage` (relative-URL resolution + hygiene filter +
/// de-dup), so logos/sprites/icons are dropped here as everywhere.
///
/// Runs **in addition to** the structured passes (not only as a last resort): a
/// page's `og:image` is often just a logo, while the good photographs are gallery /
/// CSS-background images — the candidate set the Vision recommender ranks (M4g).
enum BodyImageExtractor {
  /// `<img>` attributes that may carry the real URL (eager + common lazy-load).
  private static let imgURLAttributes = [
    "src", "data-src", "data-lazy-src", "data-original", "data-image", "data-lazy",
  ]

  /// Attributes that carry a CSS background URL on arbitrary elements.
  private static let backgroundAttributes = [
    "data-bg", "data-background", "data-background-image", "data-bg-src",
  ]

  static func extract(from document: Document, into builder: inout ParseBuilder) {
    extractImgElements(document, into: &builder)
    extractSrcsets(document, into: &builder)
    extractInlineBackgrounds(document, into: &builder)
    extractStyleBlocks(document, into: &builder)
    extractBackgroundAttributes(document, into: &builder)
    extractNoscriptFallbacks(document, into: &builder)
  }

  private static func extractImgElements(_ document: Document, into builder: inout ParseBuilder) {
    for img in (try? document.select("img").array()) ?? [] {
      for attribute in imgURLAttributes {
        if let value = try? img.attr(attribute), !value.isEmpty {
          builder.addImage(value)
        }
      }
    }
  }

  private static func extractSrcsets(_ document: Document, into builder: inout ParseBuilder) {
    for element in (try? document.select("img[srcset], source[srcset], img[data-srcset]").array())
      ?? []
    {
      let srcset = (try? element.attr("srcset")) ?? (try? element.attr("data-srcset")) ?? ""
      if let first = firstSrcsetURL(srcset) { builder.addImage(first) }
    }
  }

  private static func extractInlineBackgrounds(
    _ document: Document, into builder: inout ParseBuilder
  ) {
    for element in (try? document.select("[style]").array()) ?? [] {
      guard let style = try? element.attr("style") else { continue }
      for url in cssURLs(in: style) { builder.addImage(url) }
    }
  }

  private static func extractStyleBlocks(_ document: Document, into builder: inout ParseBuilder) {
    for style in (try? document.select("style").array()) ?? [] {
      let css = (try? style.html()) ?? ""
      for url in cssURLs(in: css) { builder.addImage(url) }
    }
  }

  private static func extractBackgroundAttributes(
    _ document: Document, into builder: inout ParseBuilder
  ) {
    for attribute in backgroundAttributes {
      for element in (try? document.select("[\(attribute)]").array()) ?? [] {
        if let value = try? element.attr(attribute), !value.isEmpty { builder.addImage(value) }
      }
    }
  }

  /// `<noscript>` content is parsed as escaped text by the HTML parser; re-parse it
  /// to recover the no-JS `<img>` fallback many lazy-loaders ship.
  private static func extractNoscriptFallbacks(
    _ document: Document, into builder: inout ParseBuilder
  ) {
    for noscript in (try? document.select("noscript").array()) ?? [] {
      guard let inner = try? noscript.html(),
        let fragment = try? SwiftSoup.parseBodyFragment(inner)
      else { continue }
      for img in (try? fragment.select("img[src]").array()) ?? [] {
        if let value = try? img.attr("src"), !value.isEmpty { builder.addImage(value) }
      }
    }
  }

  // MARK: - Parsing helpers

  /// The first candidate URL in a `srcset` ("a.jpg 1x, b.jpg 2x" → "a.jpg").
  private static func firstSrcsetURL(_ srcset: String) -> String? {
    let trimmed = srcset.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var token = trimmed
      .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
      .first.map(String.init)
    else { return nil }
    while token.hasSuffix(",") { token.removeLast() }
    return token.isEmpty ? nil : token
  }

  /// Every `url(...)` target in a CSS string (inline style or stylesheet), quotes
  /// stripped. Non-image targets (fonts, svg sprites) are dropped downstream by the
  /// hygiene filter / extension allow-list.
  private static func cssURLs(in css: String) -> [String] {
    guard css.contains("url(") else { return [] }
    let pattern = #"url\(\s*['"]?([^'")]+)['"]?\s*\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return [] }
    let range = NSRange(css.startIndex..<css.endIndex, in: css)
    return regex.matches(in: css, range: range).compactMap { match in
      guard let r = Range(match.range(at: 1), in: css) else { return nil }
      return String(css[r]).trimmingCharacters(in: .whitespaces)
    }
  }
}
