# ADR-0016: Source-aware capture and on-demand field supplement

*Status: accepted — 2026-06-22*

## Context

M6c, the enrichment half of the AI strategy (ROADMAP M6; the 2026-06-22 chat). Two
capabilities, both of which **stock and enrich the pool without a server** and lean
on machinery M4 already built:

1. **Source-aware capture.** When Jon shares a ratings page (a Michelin guide entry,
   an Andrew Harper review, a Forbes Travel Guide / World's 50 Best listing), the
   capture flow should recognize the source and record its **native** rating as an
   `IdeaEvaluation` (ADR-0015) — *in addition* to creating/matching the `Idea`.
2. **On-demand field supplement.** When a pool idea is missing a *factual* field —
   opening hours first — a per-field "supplement" affordance fills it from the
   cheapest source that can, on a tap.

Both must hold ADR-0001 (no server): on-device parsing, on-device web fetch, and a
human-in-the-loop browser are the tools, never infra Jon runs.

What already exists to build on (M4a–g): `GalavantCapture` (pure `HTML → ParsedPage`,
domain-free — it already extracts `openingHours`); `GalavantPlaces` domain bridge
(`CapturedPlace.from(ParsedPage:)` → `Idea.Draft`; `PlaceMatcher`); app-side
`PlaceEnricher` (`PageFetcher` → re-parse → backfill); the `ModelClient` boundary
(ADR-0014); and `IdeaEvaluation` (ADR-0015).

## Decision

### 1. Source-aware capture — recognizers in the pure parser, mapped in the bridge

Honor the portfolio-extraction seam (BACKLOG: the parser engine is `HTML → generic
struct` and **never sees `Idea`/`Trip`/`IdeaEvaluation`**). So the work splits the
same way the place pipeline already does:

- **`GalavantCapture` gains a domain-free `evaluations: [ParsedEvaluation]` on
  `ParsedPage`.** A `ParsedEvaluation` is a source-attributed *native* value with no
  Galavant types:

  ```swift
  // GalavantCapture — domain-free, like the rest of ParsedPage.
  public struct ParsedEvaluation: Equatable, Sendable {
    public var sourceName: String        // "Michelin Guide", "Andrew Harper"
    public var kind: ParsedEvaluationKind // stars / numericScore / rank / badge / recommendation / mention / text
    public var valueText: String         // "3 stars", "96", "No. 12"
    public var valueNumber: Double?       // 3, 96, 12
    public var valueMax: Double?          // 3, 100
    public var display: String            // "★★★", "96/100", "No. 12"
    public var guideYear: Int?
    public var evaluationDate: Date?
    public var sourceURL: String?
  }
  ```

- **Recognizers are pure `(host, ParsedPage) -> ParsedEvaluation?` functions**, run
  least→most structured into the same value-voting M4a established:
  1. **schema.org first** (M4a precedent) — JSON-LD `aggregateRating` / `Rating`
     (`ratingValue`, `bestRating`, `reviewCount`) and an explicit star/award type.
     This is the generic path that handles many sources for free.
  2. **Host recognizers** — `guide.michelin.com` → star count + `Bib`/`Green Star`
     badges + guide year; `andrewharper.com` → the 0–100 score; Forbes / 50 Best
     similarly. Each is a small pure function; host is a hint, the parsed structure
     does the work.
  3. **LLM fallback, extract-only** — when structured data is absent, the
     `ModelClient` (ADR-0014, on-device tier preferred) extracts under a strict
     "preserve native ratings exactly; do **not** invent; return null if missing"
     instruction (the artifact's extraction prompt; ADR-0015's no-authority rule).
     Deterministic recognizers always win when present.

- **`GalavantPlaces` maps `ParsedEvaluation` → `IdeaEvaluation.Draft`**, exactly as
  `CapturedPlace` maps `ParsedPage` → `Idea.Draft`. It stamps the domain fields the
  parser can't know: `confidence` (`official` for a recognized source page, `inferred`
  for the LLM path), `staleness` (`current` for a fresh guide, `historical` if the
  page carries an old date), `recordedAt`, `ideaID` (the just-matched idea),
  `travelPartyID`.

- **One transaction.** Capture creates/matches the `Idea` as today and writes the
  sibling `IdeaEvaluation`(s) in the same write. The confirm sheet (M4c
  confirm-and-tweak ethos) **shows the detected evaluation** so Jon confirms or edits
  it before save. Many recognizers can fire (Michelin *and* an embedded aggregate
  rating) → many evaluations, which ADR-0015 already allows.

### 2. On-demand field supplement — a cheapest-source ladder, fields vs judgments

A per-field **"supplement"** affordance on the idea detail. **v1 fills opening hours**
(the field most often missing and the one the start-day solver wants). The ladder,
each rung an injectable client (`inject-io-boundaries-early`):

1. **MapKit first.** The idea already carries an `MKMapItem`/coordinates from
   search-first capture. iOS 26+ `MKMapItem` may expose business hours directly —
   **verify against the SDK at build** (past Claude's cutoff; grep the Xcode-beta SDK
   headers / Apple Maps skill per `apple-sdk-headers-authoritative`). If Apple hands
   us hours, there is no scrape for the common case.
2. **The place's own official site.** The idea already stores `url`. Reuse M4g's
   `PageFetcher` + `PageParser` — `ParsedPage.openingHours` is *already extracted* —
   to pull an hours block. Legitimate and reliable.
3. **Human-in-the-loop `WKWebView`.** The universal fallback and V1's SwiftSoup
   approach reborn, interactive: an in-app browser Jon drives (renders JS, real
   session, handles consent) with a **"grab hours from this page"** action that runs
   the existing parser/extractor over the loaded DOM. This is the no-server
   enrichment workhorse.

Generalize to a **field-targeted `FieldSupplement`**: pick the cheapest rung that can
fill the requested field; later fields (menu URL, price band, booking link) reuse the
same ladder. **No Google SERP scraping** — ToS-hostile, JS-heavy, brittle; explicitly
out.

**Facts vs judgments — the load-bearing split.** Supplement fills *factual* fields on
the **`Idea`** (hours land in the existing opening-days/hours columns from M2). It
does **not** write `IdeaEvaluation` — evaluations are *judgments*, supplements are
*facts*. Write-back stamps provenance on whatever it touches: MapKit / official site →
`current`; a HITL scrape → `unverified` (or `manual` if Jon edits), so stale or
unverified facts never masquerade as authoritative (ADR-0015's staleness principle,
applied to facts).

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **Extract evaluations in the domain bridge / app, not the parser** | Rejected. Rating extraction from HTML is a pure transform; it belongs in `GalavantCapture` as a domain-free `ParsedEvaluation`, honoring the portfolio-extraction seam. The bridge only maps generic→`IdeaEvaluation`. |
| **LLM-extract every rating** | Rejected as the default. The point is the source's *exact* value; deterministic JSON-LD/host recognizers preserve it faithfully and cheaply. LLM is the structured-data-absent fallback, gated extract-only. |
| **"Supplement from Google"** (scrape the SERP) | Rejected. ToS-hostile and brittle. MapKit → official site → HITL browser is legitimate and more robust. |
| **Write supplemented hours as an `IdeaEvaluation`** | Rejected. Hours are facts about the place, not a judgment; they belong on `Idea`. Conflating them would muddy ADR-0015's native-rating model. |
| **Recognizers + ladder, facts-on-Idea / judgments-in-evaluation (chosen)** | Reuses M4's parser/fetch/enrich stack, stays domain-clean and no-server, and keeps the facts/judgments boundary crisp. |

## Relationship to prior decisions

- **ADR-0015 (evaluations):** source-aware capture is how `IdeaEvaluation` rows are
  born; the facts/judgments split keeps hours on `Idea` and ratings in the sibling.
- **ADR-0014 (model access):** the LLM extraction fallback and any HTML structuring
  run through the `ModelClient` (on-device tier preferred); extract-only, never
  inventing a rating.
- **ADR-0001 (no server):** every rung is on-device — MapKit, `URLSession` fetch,
  `WKWebView`. No relay, no backend.
- **M4a / portfolio-extraction seam:** `ParsedEvaluation` keeps the parser domain-free;
  recognizers extend the existing value-voting; the bridge does the domain mapping.
- **M4g (`PlaceEnricher`/`PageFetcher`):** the official-site rung reuses it, made
  interactive and field-targeted rather than a one-shot background pass.
- **ADR-0007:** the evaluation write follows the single-FK / loose-`ideaID` sibling
  rules ADR-0015 set.

## Consequences

- **`GalavantCapture`:** `ParsedEvaluation` + `ParsedPage.evaluations`; schema.org and
  per-host recognizers; fixture tests (a Michelin JSON-LD page, a Harper page, a
  no-structured-data page that exercises the LLM fallback boundary).
- **`GalavantPlaces`:** `ParsedEvaluation → IdeaEvaluation.Draft` mapping with
  provenance/staleness stamping; capture writes idea + evaluations in one transaction;
  confirm sheet surfaces detected evaluations.
- **`FieldSupplement`** clients (`MapKit` hours probe, official-site fetch reusing
  `PageFetcher`, HITL `WKWebView`) behind injectable boundaries; a detail-view
  "supplement hours" affordance writing back to `Idea` with provenance.
- **Open at build:** whether `MKMapItem` actually exposes hours on iOS 27 (SDK check
  decides rung 1); the HITL-browser UX; which fields follow hours; how aggressively
  the confirm sheet should pre-trust a recognized evaluation vs require a tap.
- **Known gap (2026-06-23):** hours extraction is structured-data only (JSON-LD +
  microdata), so unstructured-markup sites (e.g. Squarespace `.module--hours`
  widgets) yield nothing at capture *or* on demand — the §1 extract-only LLM
  fallback was never wired into the hours ladder. See `docs/BACKLOG.md`.
