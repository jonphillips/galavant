import Dependencies
import Foundation
import FoundationModels
import GalavantCapture
import GalavantSchema

/// On-device language-model enrichment for a captured page — the injectable cousin
/// of `PlaceMatcher`. Where the deterministic parser is brittle (a marketing chrome
/// title, no city in the structured data, a generic `schema.org` type, fluffy
/// `og:description` notes), Apple Intelligence cleans/supplements it. It is a
/// *supplementary* source: it only fills blanks and cleans low-confidence fields
/// (confirm-and-tweak, like the Apple Maps merge), and the parser stands alone
/// whenever the model is unavailable or unsure.
///
/// FoundationModels lives **only** behind the `refine` closure, so `CaptureModel`'s
/// orchestration and the `ParsedPage.applying(_:)` merge stay testable with a
/// fixture — `testValue` is a no-op (the parser-only path).
public struct PlaceIntelligence: Sendable {
  var refine: @Sendable (_ page: ParsedPage) async -> PlaceRefinement?

  public init(refine: @escaping @Sendable (_ page: ParsedPage) async -> PlaceRefinement?) {
    self.refine = refine
  }

  /// Refine a parsed page, or nil when the model is unavailable / declines.
  public func callAsFunction(_ page: ParsedPage) async -> PlaceRefinement? {
    await refine(page)
  }
}

/// The model's suggested improvements to a parsed page — all optional; any subset
/// may be present (or none). Domain-aware (`kind: IdeaKind`), so it lives here in
/// `GalavantPlaces` rather than on the domain-free `ParsedPage`. The merge applies
/// the page-level fields via `ParsedPage.applying(_:)`; `kind` is applied to the
/// draft by `CaptureModel` (only when structured data left it blank).
public struct PlaceRefinement: Equatable, Sendable {
  /// A cleaned place name — used only to replace a noisy *chrome* title.
  public var name: String?
  /// The city/locality, mined from free text when the page didn't state it
  /// (disambiguates the Apple Maps query — "Koan" → "Koan Copenhagen").
  public var locality: String?
  /// The region/state/country, mined likewise.
  public var region: String?
  /// A clean one- or two-sentence summary for notes.
  public var summary: String?
  /// The classified kind, when the page's `schema.org` type was generic/absent.
  public var kind: IdeaKind?

  public init(
    name: String? = nil,
    locality: String? = nil,
    region: String? = nil,
    summary: String? = nil,
    kind: IdeaKind? = nil
  ) {
    self.name = name
    self.locality = locality
    self.region = region
    self.summary = summary
    self.kind = kind
  }
}

extension ParsedPage {
  /// Merge the model's page-level refinements — confirm-and-tweak: never clobber
  /// what the page already supplied with structured confidence.
  ///
  /// - `title`: replaced **only when it came from chrome** (`!titleIsStructured`),
  ///   cleaning a marketing string; a structured JSON-LD/microdata `name` is
  ///   trusted verbatim. `titleIsStructured` stays `false` so a confident Apple
  ///   Maps name can still override the cleaned title later (the rule in
  ///   `CaptureModel.prepare()`).
  /// - `locality` / `region`: filled **only when the page left them blank** — this
  ///   is the city-mining that rescues a name-only page's map query.
  /// - `summary`: the model's notes are *generated* (a neutral, de-marketed
  ///   description), not a scraped fact, so they **supersede** the page's own
  ///   description when present — the raw `og:description` is usually marketing copy
  ///   we'd rather rewrite. Falls back to the page's summary when the model gives
  ///   none (or is unavailable).
  ///
  /// `kind` is intentionally *not* applied here — `ParsedPage` is domain-free;
  /// `CaptureModel` applies it to the draft.
  func applying(_ refinement: PlaceRefinement) -> ParsedPage {
    var page = self

    if !titleIsStructured, let name = refinement.name?.cleaned {
      page.title = name
    }
    if page.address.locality == nil, let locality = refinement.locality?.cleaned {
      page.address.locality = locality
    }
    if page.address.region == nil, let region = refinement.region?.cleaned {
      page.address.region = region
    }
    if let summary = refinement.summary?.cleaned {
      page.summary = summary
    }

    return page
  }
}

extension PlaceIntelligence: DependencyKey {
  public static let liveValue = PlaceIntelligence { page in
    // Apple Intelligence may be off, unsupported, or still downloading — degrade
    // silently to the deterministic parser.
    guard case .available = SystemLanguageModel.default.availability else { return nil }
    // Nothing useful was parsed — no point spending a model session.
    guard !page.isEmpty else { return nil }

    let session = LanguageModelSession(instructions: Self.instructions)
    guard
      let response = try? await session.respond(
        to: Self.prompt(for: page),
        generating: GeneratedRefinement.self
      )
    else { return nil }

    return response.content.refinement
  }

  /// No model in tests/previews — the deterministic parser stands alone.
  public static let testValue = PlaceIntelligence { _ in nil }

  private static let instructions = """
    You extract clean, structured facts about a travel place (a restaurant, hotel, \
    sight, shop, etc.) from messy web-page text. Be conservative: only return a \
    field when you are confident it is correct, otherwise leave it null. Never \
    invent a location, and do not include marketing taglines in the name.

    For the summary, write a neutral, factual description of what the place is — \
    one or two plain sentences in the third person. Do not copy the page's marketing \
    copy. Never use promotional language, taglines, questions, or calls to action \
    (e.g. "discover", "find out more", "book now"), and never address the reader as \
    "you". Describe the place, not why to visit it.
    """

  /// A compact prompt — the parsed facts plus a text excerpt give the model enough
  /// to rewrite the description even when the page has no clean one; small enough to
  /// keep the share extension's memory/latency in check.
  private static func prompt(for page: ParsedPage) -> String {
    var lines = ["Web page about a place:"]
    if let title = page.title { lines.append("Title: \(title)") }
    if let summary = page.summary { lines.append("Page description (may be marketing): \(summary)") }
    if !page.schemaTypes.isEmpty {
      lines.append("Declared types: \(page.schemaTypes.joined(separator: ", "))")
    }
    if !page.address.isEmpty { lines.append("Known address fragments: \(page.address.oneLine)") }
    if let excerpt = page.textExcerpt { lines.append("Page text:\n\(excerpt)") }
    lines.append(
      "Extract the place's proper name, its city and region/country, its kind, and a "
        + "neutral factual summary for notes (see the instructions)."
    )
    return lines.joined(separator: "\n")
  }
}

extension DependencyValues {
  public var placeIntelligence: PlaceIntelligence {
    get { self[PlaceIntelligence.self] }
    set { self[PlaceIntelligence.self] = newValue }
  }
}

/// The guided-generation shape the model fills. Kept private to the live client:
/// `FoundationModels` is an implementation detail — callers see `PlaceRefinement`.
/// `kind` is generated as a raw string constrained to the valid `IdeaKind` values
/// and mapped back, so the schema package never has to know about FoundationModels.
@Generable
private struct GeneratedRefinement {
  @Guide(description: "The place's proper name only, with no tagline or location suffix.")
  var name: String?

  @Guide(description: "The city or locality the place is in.")
  var city: String?

  @Guide(description: "The region, state, or country the place is in.")
  var region: String?

  @Guide(
    description: "A neutral, factual one- or two-sentence description of the place "
      + "in the third person, with no marketing language, questions, or calls to action."
  )
  var summary: String?

  @Guide(
    description: "The kind of place, if clear from the text.",
    .anyOf(IdeaKind.allCases.map(\.rawValue))
  )
  var kind: String?

  var refinement: PlaceRefinement {
    PlaceRefinement(
      name: name?.cleaned,
      locality: city?.cleaned,
      region: region?.cleaned,
      summary: summary?.cleaned,
      kind: kind.flatMap { IdeaKind(rawValue: $0) }
    )
  }
}

extension String {
  /// Trimmed, or nil when empty after trimming — the model sometimes emits blanks
  /// or whitespace for "no value."
  fileprivate var cleaned: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
