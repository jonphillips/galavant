import Foundation
import SwiftSoup

/// Pure recognizers that read a page's *native* source judgments into
/// `ParsedEvaluation`s (ADR-0016 §1). Run **least → most structured**, deterministic
/// first: schema.org `aggregateRating`/`Rating` (the generic path many sources ship
/// for free), then per-host recognizers (Michelin / Andrew Harper / Forbes / 50
/// Best) keyed on the source URL's host. Each is a small pure function; the host is
/// a hint, the parsed structure or distinct text pattern does the work.
///
/// Domain-free, like the rest of the engine — it yields `ParsedEvaluation`, never an
/// `IdeaEvaluation`. When *no* deterministic recognizer fires, the bridge's on-device
/// LLM extract-only fallback (`EvaluationExtractor`) takes over (ADR-0016 §1).
enum EvaluationRecognizers {
  /// Detect every native judgment on the page. The order matters only for the
  /// de-dup in `ParseBuilder.addEvaluation` (first-seen wins): schema.org first,
  /// then host recognizers.
  static func recognize(in document: Document, sourceURL: URL?) -> [ParsedEvaluation] {
    var builder = ParseBuilder(sourceURL: sourceURL)
    let host = sourceURL?.host()?.lowercased() ?? ""
    let pageText = (try? document.text()) ?? ""
    let urlString = sourceURL?.absoluteString
    let year = guideYear(in: pageText)

    for node in jsonLDNodes(in: document) {
      if let rating = aggregateRating(from: node, sourceURL: urlString) {
        builder.addEvaluation(rating)
      }
      for award in awards(from: node, sourceURL: urlString, guideYear: year) {
        builder.addEvaluation(award)
      }
    }

    // Per-host recognizers, dispatched off the shared `GuideHosts` table so the host
    // fragments live in exactly one place (and stay in lockstep with `GuideLinkRecognizer`).
    switch GuideHosts.guide(forHost: host)?.name {
    case GuideHosts.michelin.name?:
      if let michelin = michelin(in: pageText, sourceURL: urlString, guideYear: year) {
        builder.addEvaluation(michelin)
      }
    case GuideHosts.andrewHarper.name?:
      if let harper = harper(in: pageText, sourceURL: urlString) { builder.addEvaluation(harper) }
    case GuideHosts.forbes.name?:
      if let forbes = forbes(in: pageText, sourceURL: urlString) { builder.addEvaluation(forbes) }
    case GuideHosts.fiftyBest.name?:
      if let rank = fiftyBest(in: pageText, sourceURL: urlString, guideYear: year) {
        builder.addEvaluation(rank)
      }
    default:
      break
    }

    return builder.evaluations
  }

  // MARK: - schema.org (generic)

  /// A JSON-LD `aggregateRating` → a `numericScore` keyed to its author/publisher
  /// when named, else a neutral "Aggregate rating". Preserves the source's own scale
  /// (`bestRating`); never rescales.
  private static func aggregateRating(from node: [String: Any], sourceURL: String?) -> ParsedEvaluation? {
    guard let rating = node["aggregateRating"] as? [String: Any],
      let value = number(rating["ratingValue"])
    else { return nil }
    let max = number(rating["bestRating"]) ?? 5
    let source = string(rating["author"]) ?? string(node["publisher"]) ?? "Aggregate rating"
    let valueText = formatted(value)
    return ParsedEvaluation(
      sourceName: source,
      kind: .numericScore,
      valueText: valueText,
      valueNumber: value,
      valueMax: max,
      display: "\(valueText)/\(formatted(max))",
      sourceURL: sourceURL
    )
  }

  /// JSON-LD `award`(s) — a string or array. Michelin-style star awards become
  /// `stars`; everything else is a `badge` (Bib Gourmand, Green Star, a membership).
  private static func awards(
    from node: [String: Any], sourceURL: String?, guideYear: Int?
  ) -> [ParsedEvaluation] {
    let raw: [String]
    switch node["award"] ?? node["awards"] {
    case let string as String: raw = [string]
    case let array as [Any]: raw = array.compactMap { $0 as? String }
    default: raw = []
    }
    return raw.compactMap { award in
      if let stars = michelinStars(in: award) {
        return starsEvaluation(stars, source: GuideHosts.michelin.name, sourceURL: sourceURL, guideYear: guideYear)
      }
      let badge = badgeKind(in: award)
      if let badge {
        return ParsedEvaluation(
          sourceName: badge.source, kind: .badge, valueText: badge.label,
          display: badge.label, guideYear: guideYear, sourceURL: sourceURL
        )
      }
      return nil
    }
  }

  // MARK: - Per-host recognizers

  /// guide.michelin.com — star count, then Bib Gourmand / Green Star / Plate, from
  /// the page text (the host's JSON-LD often omits the distinction).
  private static func michelin(in text: String, sourceURL: String?, guideYear: Int?) -> ParsedEvaluation? {
    if let stars = michelinStars(in: text) {
      return starsEvaluation(stars, source: GuideHosts.michelin.name, sourceURL: sourceURL, guideYear: guideYear)
    }
    if let badge = badgeKind(in: text), badge.source == GuideHosts.michelin.name {
      return ParsedEvaluation(
        sourceName: badge.source, kind: .badge, valueText: badge.label,
        display: badge.label, guideYear: guideYear, sourceURL: sourceURL
      )
    }
    if text.range(of: "michelin plate", options: .caseInsensitive) != nil
      || text.range(of: "michelin recommended", options: .caseInsensitive) != nil
    {
      return ParsedEvaluation(
        sourceName: GuideHosts.michelin.name, kind: .recommendation, valueText: "Recommended",
        display: "Recommended", guideYear: guideYear, sourceURL: sourceURL
      )
    }
    return nil
  }

  /// andrewharper.com — a 0–100 score (e.g. "96/100" or "Score 96").
  private static func harper(in text: String, sourceURL: String?) -> ParsedEvaluation? {
    guard let score = score(outOf: 100, in: text) else { return nil }
    let valueText = formatted(score)
    return ParsedEvaluation(
      sourceName: GuideHosts.andrewHarper.name, kind: .numericScore, valueText: valueText,
      valueNumber: score, valueMax: 100, display: "\(valueText)/100", sourceURL: sourceURL
    )
  }

  /// forbestravelguide.com — a Four-/Five-Star rating, else a Recommended listing.
  private static func forbes(in text: String, sourceURL: String?) -> ParsedEvaluation? {
    if let stars = spelledStars(in: text, suffix: "-star") {
      return starsEvaluation(stars, source: GuideHosts.forbes.name, sourceURL: sourceURL, guideYear: nil)
    }
    if text.range(of: "recommended", options: .caseInsensitive) != nil {
      return ParsedEvaluation(
        sourceName: GuideHosts.forbes.name, kind: .recommendation, valueText: "Recommended",
        display: "Recommended", sourceURL: sourceURL
      )
    }
    return nil
  }

  /// theworlds50best.com — a list position ("No. 12" / "#12").
  private static func fiftyBest(in text: String, sourceURL: String?, guideYear: Int?) -> ParsedEvaluation? {
    guard let rank = rank(in: text) else { return nil }
    return ParsedEvaluation(
      sourceName: GuideHosts.fiftyBest.name, kind: .rank, valueText: "No. \(rank)",
      valueNumber: Double(rank), display: "No. \(rank)", guideYear: guideYear, sourceURL: sourceURL
    )
  }

  // MARK: - Shared value parsing

  private static func starsEvaluation(
    _ count: Int, source: String, sourceURL: String?, guideYear: Int?
  ) -> ParsedEvaluation {
    ParsedEvaluation(
      sourceName: source,
      kind: .stars,
      valueText: "\(count) star\(count == 1 ? "" : "s")",
      valueNumber: Double(count),
      valueMax: source == GuideHosts.michelin.name ? 3 : nil,
      display: String(repeating: "★", count: count),
      guideYear: guideYear,
      sourceURL: sourceURL
    )
  }

  /// A Michelin star count (1–3) from "N MICHELIN Star(s)" / "Three MICHELIN Stars".
  private static func michelinStars(in text: String) -> Int? {
    guard text.range(of: "michelin", options: .caseInsensitive) != nil
      || text.range(of: "star", options: .caseInsensitive) != nil
    else { return nil }
    // Require "star" to be near a count word, anchored to MICHELIN where possible.
    if let count = spelledStars(in: text, suffix: " michelin star"), (1...3).contains(count) {
      return count
    }
    if let count = spelledStars(in: text, suffix: " star"), (1...3).contains(count) {
      return count
    }
    return nil
  }

  /// A leading star count before `suffix`, spelled ("three") or numeric ("3"),
  /// case-insensitive and tolerant of plural/joined suffixes.
  private static func spelledStars(in text: String, suffix: String) -> Int? {
    let lower = text.lowercased()
    let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5]
    for (word, value) in words where lower.contains("\(word)\(suffix)") {
      return value
    }
    for value in 1...5 where lower.contains("\(value)\(suffix)") {
      return value
    }
    return nil
  }

  /// A "score / 100" anywhere in the text, or "Score 96" → 96.
  private static func score(outOf max: Int, in text: String) -> Double? {
    if let match = firstMatch(#"(\d{1,3})\s*/\s*\#(max)\b"#, in: text), let value = Double(match) {
      return value
    }
    if let match = firstMatch(#"\bscore[:\s]+(\d{1,3})\b"#, in: text), let value = Double(match),
      value <= Double(max)
    {
      return value
    }
    return nil
  }

  /// A rank like "No. 12", "No 12", or "#12".
  private static func rank(in text: String) -> Int? {
    if let match = firstMatch(#"\bno\.?\s*(\d{1,3})\b"#, in: text), let value = Int(match) {
      return value
    }
    if let match = firstMatch(#"#\s*(\d{1,3})\b"#, in: text), let value = Int(match) {
      return value
    }
    return nil
  }

  /// A four-digit guide year next to "guide" / "edition", e.g. "MICHELIN Guide 2024".
  private static func guideYear(in text: String) -> Int? {
    if let match = firstMatch(#"(?:guide|edition)\s+(\d{4})"#, in: text), let year = Int(match) {
      return year
    }
    if let match = firstMatch(#"(\d{4})\s+(?:guide|edition)"#, in: text), let year = Int(match) {
      return year
    }
    return nil
  }

  /// Map known badge phrases to a (source, label). `nil` when no badge is present.
  private static func badgeKind(in text: String) -> (source: String, label: String)? {
    let lower = text.lowercased()
    if lower.contains("bib gourmand") { return (GuideHosts.michelin.name, "Bib Gourmand") }
    if lower.contains("green star") { return (GuideHosts.michelin.name, "Green Star") }
    if lower.contains("relais & châteaux") || lower.contains("relais & chateaux") {
      return ("Relais & Châteaux", "Member")
    }
    return nil
  }

  // MARK: - JSON-LD + JSON coercion

  /// Every dictionary node in the page's JSON-LD scripts, walked recursively
  /// (through arrays and `@graph`). Tolerates the same curly-quote breakage the
  /// place extractor cleans.
  private static func jsonLDNodes(in document: Document) -> [[String: Any]] {
    let scripts = (try? document.select("script[type=application/ld+json]").array()) ?? []
    var nodes: [[String: Any]] = []
    for script in scripts {
      guard let data = cleanedJSON(script.data()),
        let top = try? JSONSerialization.jsonObject(with: data)
      else { continue }
      nodes.append(contentsOf: dictionaries(in: top))
    }
    return nodes
  }

  private static func dictionaries(in value: Any) -> [[String: Any]] {
    switch value {
    case let dict as [String: Any]:
      return [dict] + dict.values.flatMap(dictionaries(in:))
    case let array as [Any]:
      return array.flatMap(dictionaries(in:))
    default:
      return []
    }
  }

  private static func cleanedJSON(_ raw: String) -> Data? {
    raw
      .replacingOccurrences(of: "[\u{201C}\u{201D}\u{2019}]", with: "", options: .regularExpression)
      .data(using: .utf8)
  }

  /// A scalar JSON value as a string — resolves a `{ "name": … }` node to its name.
  private static func string(_ value: Any?) -> String? {
    switch value {
    case let string as String:
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    case let dict as [String: Any]:
      return string(dict["name"] ?? dict["legalName"])
    case let array as [Any]:
      return array.lazy.compactMap(string).first
    default:
      return nil
    }
  }

  private static func number(_ value: Any?) -> Double? {
    switch value {
    case let number as NSNumber: return number.doubleValue
    case let string as String: return Double(string.trimmingCharacters(in: .whitespaces))
    default: return nil
    }
  }

  /// Trim a trailing ".0" so "3.0" reads "3" but "4.5" stays "4.5".
  private static func formatted(_ value: Double) -> String {
    value == value.rounded() ? String(Int(value)) : String(value)
  }

  /// First capture group of `pattern` (case-insensitive) in `text`, or nil.
  private static func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return nil
    }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
      let captured = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[captured])
  }
}
