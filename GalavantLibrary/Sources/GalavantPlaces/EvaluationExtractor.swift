import Dependencies
import Foundation
import LLMClientKit
import GalavantCapture

/// The **extract-only** LLM fallback for source-aware capture (ADR-0016 §1): when
/// the deterministic recognizers (`EvaluationRecognizers`) find no native rating,
/// the on-device model reads the page text and pulls out any rating it states —
/// *preserving it exactly, never inventing one*. Deterministic recognizers always
/// win; this fires only when `page.evaluations` is empty.
///
/// Routed through the `ModelClient` boundary (ADR-0014) at the **on-device tier** —
/// the page never leaves the device for a mere rating extraction. Injectable like
/// `PlaceIntelligence`: the live value calls the model, `testValue` is a no-op so the
/// deterministic path is the tested default.
public struct EvaluationExtractor: Sendable {
  var extract: @Sendable (_ page: ParsedPage) async -> [ParsedEvaluation]

  public init(extract: @escaping @Sendable (_ page: ParsedPage) async -> [ParsedEvaluation]) {
    self.extract = extract
  }

  /// Extracted evaluations, or empty when the page states none / the model is
  /// unavailable. Always returns native values — extraction, never judgment.
  public func callAsFunction(_ page: ParsedPage) async -> [ParsedEvaluation] {
    await extract(page)
  }
}

extension EvaluationExtractor: DependencyKey {
  public static let liveValue = EvaluationExtractor { page in
    @Dependency(\.modelClient) var modelClient
    guard let excerpt = page.textExcerpt, !excerpt.isEmpty else { return [] }
    let request = ModelRequest(
      tier: .onDevice,
      system: Self.instructions,
      prompt: Self.prompt(for: page, excerpt: excerpt),
      maxTokens: 512
    )
    guard let response = try? await modelClient.complete(request) else { return [] }
    return Self.parse(response.text, sourceURL: page.sourceURL?.absoluteString)
  }

  /// No model in tests/previews — the deterministic recognizers stand alone.
  public static let testValue = EvaluationExtractor { _ in [] }

  static let instructions = """
    You extract ratings or awards a web page states from a named source (a guide, a \
    critic, a ranking). Preserve each rating exactly as the source expresses it; never \
    invent, infer, or normalize a rating, and never convert one scale to another. If \
    the page states no explicit third-party rating, return an empty list.

    Respond with ONLY a JSON array (no prose). Each element has: "sourceName" (the \
    judging source), "kind" (one of stars, numericScore, rank, badge, recommendation, \
    mention, text), "valueText" (the value verbatim, e.g. "3 stars", "96", "No. 12"), \
    "display" (how to show it, e.g. "★★★", "96/100", "No. 12"), and optionally \
    "valueNumber" and "valueMax" as numbers. Return [] when there is nothing.
    """

  private static func prompt(for page: ParsedPage, excerpt: String) -> String {
    var lines = ["Web page:"]
    if let title = page.title { lines.append("Title: \(title)") }
    lines.append("Text:\n\(excerpt)")
    lines.append("Extract any explicitly stated third-party ratings or awards as JSON.")
    return lines.joined(separator: "\n")
  }

  /// Parse the model's JSON array defensively — a non-array, a missing field, or an
  /// unknown kind drops that element rather than failing the whole extraction.
  static func parse(_ text: String, sourceURL: String?) -> [ParsedEvaluation] {
    guard let data = jsonArraySlice(text)?.data(using: .utf8),
      let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return array.compactMap { element in
      guard let sourceName = (element["sourceName"] as? String)?.nonEmpty,
        let kind = (element["kind"] as? String).flatMap(ParsedEvaluationKind.init(rawValue:)),
        let valueText = (element["valueText"] as? String)?.nonEmpty
      else { return nil }
      let display = (element["display"] as? String)?.nonEmpty ?? valueText
      return ParsedEvaluation(
        sourceName: sourceName,
        kind: kind,
        valueText: valueText,
        valueNumber: (element["valueNumber"] as? NSNumber)?.doubleValue,
        valueMax: (element["valueMax"] as? NSNumber)?.doubleValue,
        display: display,
        sourceURL: sourceURL
      )
    }
  }

  /// Slice out the outermost `[ … ]` so chatty models that wrap the array in prose
  /// still parse. `nil` when no array is present.
  private static func jsonArraySlice(_ text: String) -> String? {
    guard let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]"), open < close
    else { return nil }
    return String(text[open...close])
  }
}

extension DependencyValues {
  public var evaluationExtractor: EvaluationExtractor {
    get { self[EvaluationExtractor.self] }
    set { self[EvaluationExtractor.self] = newValue }
  }
}

extension String {
  fileprivate var nonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
