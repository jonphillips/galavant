import Dependencies
import Foundation
import GalavantAI
import GalavantCapture

/// The **extract-only** LLM fallback for opening hours (ADR-0016 §2; docs/BACKLOG.md
/// "Hours extraction misses unstructured-markup sites"). The deterministic parser
/// mines hours only from JSON-LD / microdata, so small-business sites that render
/// hours as a styled widget with no schema.org markup (Squarespace/Wix/Webflow —
/// brewerybhavana.com is the canonical miss) yield nothing. When the parser comes up
/// empty, the on-device model reads the page text and pulls out the stated hours
/// *exactly* — never inferring or inventing them.
///
/// Mirrors `EvaluationExtractor`: routed through the `ModelClient` boundary (ADR-0014)
/// at the **on-device tier**, so the page never leaves the device for a mere hours
/// extraction. Injectable like `PlaceIntelligence` — the live value calls the model,
/// `testValue` returns `nil` so the deterministic parser stays the tested default.
public struct HoursExtractor: Sendable {
  var extract: @Sendable (_ page: ParsedPage) async -> String?

  public init(extract: @escaping @Sendable (_ page: ParsedPage) async -> String?) {
    self.extract = extract
  }

  /// The page's stated opening-hours block, or `nil` when the page states none / the
  /// model is unavailable. Always extraction, never invention.
  public func callAsFunction(_ page: ParsedPage) async -> String? {
    await extract(page)
  }
}

extension HoursExtractor: DependencyKey {
  public static let liveValue = HoursExtractor { page in
    @Dependency(\.modelClient) var modelClient
    guard let excerpt = page.textExcerpt, !excerpt.isEmpty else { return nil }
    let request = ModelRequest(
      tier: .onDevice,
      system: Self.instructions,
      prompt: Self.prompt(for: page, excerpt: excerpt),
      maxTokens: 256
    )
    guard let response = try? await modelClient.complete(request) else { return nil }
    return Self.parse(response.text)
  }

  /// No model in tests/previews — the deterministic parser stands alone.
  public static let testValue = HoursExtractor { _ in nil }

  static let instructions = """
    You extract a place's opening hours from a web page, exactly as the page states \
    them, at weekday granularity. Never infer, guess, normalize, or invent hours; if \
    the page states no opening hours, return null.

    Respond with ONLY a JSON object (no prose): {"hours": "<the hours, one line per \
    day or the page's own compact range>"} — or {"hours": null} when the page states \
    none. Preserve the page's own wording and times.
    """

  private static func prompt(for page: ParsedPage, excerpt: String) -> String {
    var lines = ["Web page:"]
    if let title = page.title { lines.append("Title: \(title)") }
    lines.append("Text:\n\(excerpt)")
    lines.append("Extract the opening hours as JSON.")
    return lines.joined(separator: "\n")
  }

  /// Parse the model's JSON object defensively — a non-object, a missing/null/blank
  /// `"hours"` field, or any malformed output degrades to `nil` rather than crashing.
  static func parse(_ text: String) -> String? {
    guard let data = jsonObjectSlice(text)?.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let hours = object["hours"] as? String
    else { return nil }
    let trimmed = hours.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Slice out the outermost `{ … }` so a chatty model that wraps the object in prose
  /// still parses. `nil` when no object is present.
  private static func jsonObjectSlice(_ text: String) -> String? {
    guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close
    else { return nil }
    return String(text[open...close])
  }
}

extension DependencyValues {
  public var hoursExtractor: HoursExtractor {
    get { self[HoursExtractor.self] }
    set { self[HoursExtractor.self] = newValue }
  }
}
