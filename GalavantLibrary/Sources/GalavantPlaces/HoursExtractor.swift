import Dependencies
import Foundation
import LLMClientKit
import GalavantCapture
import GalavantSchema

/// The **extract-only** LLM fallback for opening hours (ADR-0016 §2; docs/BACKLOG.md
/// "Hours extraction misses unstructured-markup sites"). The deterministic parser
/// mines hours only from JSON-LD / microdata, so small-business sites that render
/// hours as a styled widget with no schema.org markup (Squarespace/Wix/Webflow —
/// brewerybhavana.com is the canonical miss) yield nothing. When the parser comes up
/// empty, the on-device model reads the page text and pulls out the stated hours
/// *exactly* — never inferring or inventing them.
///
/// Two shapes, same discipline: `callAsFunction` returns the free-form **string** block
/// (ADR-0016); `structured` returns the **`WeeklyHours`** value the start-day solver
/// reads (ADR-0029 §3.2), including a `ServicePeriod.meal` set directly when the prose
/// states it ("dinner only", "no lunch Mondays") — the case deterministic derivation
/// can't reach.
///
/// Mirrors `EvaluationExtractor`: routed through the `ModelClient` boundary (ADR-0014)
/// at the **on-device tier**, so the page never leaves the device for a mere hours
/// extraction. Injectable like `PlaceIntelligence` — the live value calls the model,
/// `testValue` returns `nil` so the deterministic parser stays the tested default.
public struct HoursExtractor: Sendable {
  var extract: @Sendable (_ page: ParsedPage) async -> String?
  var extractStructured: @Sendable (_ page: ParsedPage) async -> WeeklyHours?

  public init(
    extract: @escaping @Sendable (_ page: ParsedPage) async -> String?,
    structured: @escaping @Sendable (_ page: ParsedPage) async -> WeeklyHours?
  ) {
    self.extract = extract
    self.extractStructured = structured
  }

  /// String-only convenience (structured hours fall back to none) — for call sites
  /// exercising just the free-form hours path.
  public init(extract: @escaping @Sendable (_ page: ParsedPage) async -> String?) {
    self.init(extract: extract, structured: { _ in nil })
  }

  /// The page's stated opening-hours block, or `nil` when the page states none / the
  /// model is unavailable. Always extraction, never invention.
  public func callAsFunction(_ page: ParsedPage) async -> String? {
    await extract(page)
  }

  /// The page's stated hours structured to weekday granularity with meal labels where
  /// the prose gives them, or `nil` when the page states none / the model is
  /// unavailable. Always extraction, never invention.
  public func structured(_ page: ParsedPage) async -> WeeklyHours? {
    await extractStructured(page)
  }
}

extension HoursExtractor: DependencyKey {
  public static let liveValue = HoursExtractor(
    extract: { page in
      @Dependency(\.modelClient) var modelClient
      // Hours sit deep in the body or a bottom-of-page contact block — read the fuller
      // `bodyText`, falling back to the short summary excerpt only when it's absent.
      guard let excerpt = page.bodyText ?? page.textExcerpt, !excerpt.isEmpty else { return nil }
      let request = ModelRequest(
        tier: .onDevice,
        system: Self.instructions,
        prompt: Self.prompt(for: page, excerpt: excerpt),
        maxTokens: 256
      )
      guard let response = try? await modelClient.complete(request) else { return nil }
      return Self.parse(response.text)
    },
    structured: { page in
      @Dependency(\.modelClient) var modelClient
      guard let excerpt = page.bodyText ?? page.textExcerpt, !excerpt.isEmpty else { return nil }
      let request = ModelRequest(
        tier: .onDevice,
        system: Self.structuredInstructions,
        prompt: Self.structuredPrompt(for: page, excerpt: excerpt),
        maxTokens: 512
      )
      guard let response = try? await modelClient.complete(request) else { return nil }
      return Self.parseStructured(response.text)
    }
  )

  /// No model in tests/previews — the deterministic parser stands alone.
  public static let testValue = HoursExtractor(extract: { _ in nil }, structured: { _ in nil })

  static let instructions = """
    You extract a place's opening hours from a web page, exactly as the page states \
    them, at weekday granularity. Never infer, guess, normalize, or invent hours; if \
    the page states no opening hours, return null.

    Respond with ONLY a JSON object (no prose): {"hours": "<the hours, one line per \
    day or the page's own compact range>"} — or {"hours": null} when the page states \
    none. Preserve the page's own wording and times.
    """

  static let structuredInstructions = """
    You extract a place's opening hours from a web page into a structured weekly \
    schedule, exactly as the page states them. Never infer, guess, or invent hours or \
    meals. Only include what the page actually states.

    Respond with ONLY a JSON object (no prose) of this shape:
    {"week":[{"day":"monday","status":"open","periods":[{"meal":"dinner","open":"18:00","close":"22:00"}]}, ...]}

    Rules:
    - "day" is one of monday tuesday wednesday thursday friday saturday sunday.
    - "status" is "open", "closed", or "unknown". Use "closed" ONLY when the page \
    states the place is closed that day. Use "unknown" (or omit the day entirely) when \
    the page says nothing about that day — never assume closed.
    - "periods" lists each service sitting for an open day. Each period may carry \
    "meal" (breakfast, lunch, dinner, lateNight) when the page names the meal \
    ("dinner only" → meal "dinner", no times), "open"/"close" as "HH:mm" 24h clock \
    when the page gives times, or both. Omit "periods" for an open day with no detail.
    - Split lunch/dinner service is two periods.
    """

  private static func prompt(for page: ParsedPage, excerpt: String) -> String {
    var lines = ["Web page:"]
    if let title = page.title { lines.append("Title: \(title)") }
    lines.append("Text:\n\(excerpt)")
    lines.append("Extract the opening hours as JSON.")
    return lines.joined(separator: "\n")
  }

  private static func structuredPrompt(for page: ParsedPage, excerpt: String) -> String {
    var lines = ["Web page:"]
    if let title = page.title { lines.append("Title: \(title)") }
    lines.append("Text:\n\(excerpt)")
    lines.append("Extract the weekly opening hours as structured JSON.")
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

  /// Decode the model's weekly-schedule JSON into `WeeklyHours`, defensively — any
  /// malformed field is skipped, an unknown/absent day stays `.unknown`, and a result
  /// asserting nothing degrades to `nil` (so the caller keeps no structured hours
  /// rather than an empty blob). Never crashes on bad model output.
  static func parseStructured(_ text: String) -> WeeklyHours? {
    guard let data = jsonObjectSlice(text)?.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let week = object["week"] as? [Any]
    else { return nil }

    var days = Array(repeating: DayHours.unknown, count: 7)
    for case let entry as [String: Any] in week {
      guard let dayName = entry["day"] as? String, let weekday = weekday(named: dayName) else {
        continue
      }
      let status = (entry["status"] as? String)?.lowercased() ?? "open"
      switch status {
      case "closed":
        days[weekday.rawValue] = .closed
      case "unknown":
        days[weekday.rawValue] = .unknown
      default:
        let periods = (entry["periods"] as? [Any] ?? []).compactMap { servicePeriod($0) }
        days[weekday.rawValue] = .open(periods)
      }
    }
    let hours = WeeklyHours(days: days)
    return hours.hasAnyAssertion ? hours : nil
  }

  private static func servicePeriod(_ value: Any) -> ServicePeriod? {
    guard let dict = value as? [String: Any] else { return nil }
    let meal = (dict["meal"] as? String).flatMap { Meal(rawValue: normalizedMeal($0)) }
    let open = (dict["open"] as? String).flatMap(minute(fromClock:))
    let close = (dict["close"] as? String).flatMap(minute(fromClock:))
    let interval: OpenInterval? =
      if let open, let close { OpenInterval(open: open, close: close <= open ? close + 24 * 60 : close) }
      else { nil }
    // Invariant: at least one of meal / interval — drop an empty period.
    guard meal != nil || interval != nil else { return nil }
    return ServicePeriod(meal: meal, interval: interval)
  }

  private static func weekday(named name: String) -> Weekday? {
    switch name.trimmingCharacters(in: .whitespaces).lowercased().prefix(2) {
    case "mo": .monday
    case "tu": .tuesday
    case "we": .wednesday
    case "th": .thursday
    case "fr": .friday
    case "sa": .saturday
    case "su": .sunday
    default: nil
    }
  }

  /// Normalize the model's meal wording to a `Meal` raw value ("late night" /
  /// "late-night" → "lateNight"; anything else passes through lowercased).
  private static func normalizedMeal(_ raw: String) -> String {
    let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
    if key.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
      == "latenight"
    {
      return "lateNight"
    }
    return key
  }

  private static func minute(fromClock clock: String) -> Int? {
    let parts = clock.split(separator: ":")
    guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
      (0...29).contains(hour), (0..<60).contains(minute)
    else { return nil }
    return hour * 60 + minute
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
