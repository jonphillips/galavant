# ADR-0021: Guide-link enrichment rung — follow one recognized guide link

*Status: accepted — 2026-06-24*

## Context

First-use feedback: *"on the Michelin web page there is a link to
`guide.michelin.com/.../es-senz` … would it ever find that and visit it to
supplement?"* Today: **no.**

The app-side second hop (`PlaceEnricher.enrichIfNeeded`,
[GalavantPlaces/PlaceEnricher.swift]) re-fetches the idea's **own** `websiteURL`
(`Idea.url`, extracted at capture) and re-parses it. It never follows a link found
*in the page body*. So when a restaurant's own site links out to its Michelin guide
detail page — where the ★★★ actually lives — that rating is never collected unless
the user happened to share the guide page directly.

Two concrete gaps make the link invisible to the pipeline:

- **`ParsedPage` carries no general body links.** It surfaces `imageURLs`,
  `socialURLs`, and a single advertised `websiteURL` ([GalavantCapture/ParsedPage.swift])
  — but no list of the page's outbound anchors. Nothing downstream can even *see* the
  guide-detail link.
- **`EvaluationRecognizers` is host-keyed but only ever runs on the page in hand.**
  It already switches on `sourceURL.host()` and runs Michelin / Andrew Harper / Forbes
  / World's 50 Best recognizers ([GalavantCapture/EvaluationRecognizers.swift]) — the
  machinery to read a guide page is built. It's just never *pointed at* a guide page
  the enricher hasn't fetched.

The enricher also **does not record evaluations at all today** — evaluations are
written only at capture time (`CaptureModel`, via `IdeaEvaluation.record`). Following
a guide link is therefore also the moment the second hop starts contributing
judgments, not just facts.

This is the natural successor to ADR-0016 (source-aware capture → `IdeaEvaluation`)
and ADR-0019 (capture dedup): 0016 reads judgments off the shared page, 0021 reads
the judgment off the page *the shared page points to*, and ADR-0019's idempotent
de-dup keeps the result from doubling up.

**In scope:** the automated rung — a plain `URLSession` fetch of one recognized
guide link during the existing second hop. **Out of scope (deliberately):** the
human-in-the-loop rendered-DOM browser fallback for JS-heavy / anti-bot guide pages.
That is the *same* effort's next rung (generalize `HoursBrowserView` into a reusable
"render URL → hand back HTML → run any extractor" component), but we ship the
automated rung first — it handles the static guide pages and surfaces *which* pages
actually need rendering. See docs/BACKLOG.md.

## Decision

### 1. `ParsedPage` gains general body links (parser change)

`PageParser` collects outbound anchor hrefs into a new field:

```swift
public var links: [URL]   // absolute http(s) anchors, in document order, de-duplicated
```

Collected in `ParseBuilder` like the other order-preserving, de-duplicated
collections (`addLink`, mirroring `addSocial`). Filtered to the raw minimum the field
promises — **absolute `http`/`https` only** (drop `mailto:`/`tel:`/`javascript:`/
in-page `#fragments`), and **excluding the page's own `sourceURL`**. Everything
narrower than that — *which* links matter — is a consumer's concern, not the
domain-free parser's. No count cap: `ParsedPage` is a transient value (never
persisted), and the recognizer in §2 narrows hundreds of anchors to at most a handful
immediately.

### 2. `GuideLinkRecognizer` — pure, host + path-shape heuristic

A new pure recognizer in `GalavantCapture` (sibling to `EvaluationRecognizers`,
domain-free), input `ParsedPage`, output the recognized guide-detail links best-first:

```swift
struct RecognizedGuideLink: Equatable { var url: URL; var guide: String }
GuideLinkRecognizer.recognize(in page: ParsedPage) -> [RecognizedGuideLink]
```

A link is a guide-detail candidate when **both** hold:

- **(a) Host is a known guide.** The host list `EvaluationRecognizers` already
  switches on is lifted into one shared `GuideHosts` table (host fragment → guide
  display name: `michelin` → "Michelin Guide", `andrewharper` → "Andrew Harper",
  `forbestravelguide` → "Forbes Travel Guide", `theworlds50best`/`50best` → "World's
  50 Best"). `EvaluationRecognizers` is refactored to consume the same table, so the
  two recognizers can never drift apart — there is exactly one definition of "a guide."

- **(b) Path looks like a *place-detail* page, not a home/section/listing index.**
  Two signals, OR'd:
  - a known **detail-path marker** segment (Michelin's `/restaurant/` or `/hotel/`),
    where we know the guide's stable scheme; **or**
  - a generic **depth** shape: at least `minGuideDetailDepth` non-empty path segments
    with a final segment that isn't a section keyword (`restaurants`, `hotels`,
    `the-list`, `search`, `destinations`, …).

  `minGuideDetailDepth = 3`. **Rationale (not a tuned middle number):** guides
  namespace by locale → region/category → place, so a per-place page cannot exist
  shallower than locale(1) + region/category(2) + the place's own slug(3). A home page
  is depth 0, a locale or category index 1–2; the individual place's detail page is the
  first thing that *must* reach depth 3. The section-keyword guard then rejects a
  depth-3 listing index (which ends in a plural section word). We **don't** additionally
  require a hyphenated slug — single-word place names (`disfrutar`, `noma`) are common,
  and a hyphen test silently dropped them. The cost is occasionally following a deep
  geographic index on a marker-less guide; the hop is best-effort and one-shot, and the
  idempotent record (below) de-dups whatever it yields. The marker path short-circuits
  this for Michelin, the motivating case.

If neither signal is reliable for a given guide we simply don't follow its links —
a false negative costs us nothing (the rating was already invisible), whereas a false
positive wastes a fetch on a listing page and risks recording a mismatched rating.

### 3. One enrichment hop in `PlaceEnricher` — merge evaluations + blank facts

Inside the existing once-per-idea `enrichIfNeeded` (already gated on `enrichedAt`),
after the main-hop parse of `idea.url`:

1. `GuideLinkRecognizer.recognize(in: page)` over the main page's links; take the
   **first** candidate.
2. Fetch **at most one** link via the enricher's existing `pageFetcher`, parse it
   (`sourceURL` = the guide URL, so the host recognizers fire → ★★★), and **merge it
   into the main page**, fill-blanks-only: `ParsedPage.fillingBlanks(from:)` — a new
   pure helper that fills blank scalar facts from the other page and appends its
   evaluations through the same (source, kind, value) de-dup `ParseBuilder` already
   uses. The single existing DB write then resolves facts and, **new**, records the
   merged page's evaluations.
3. **Record evaluations** via `IdeaEvaluation.record` (ADR-0016 bridge), stamped
   `.official` (deterministic recognizer), idempotent on the source/kind/value triad
   (ADR-0019 §3, compared **case-insensitively** in lockstep with the parser/merge).
   Requires a non-nil `Idea.travelPartyID`; skipped when nil (no regression —
   facts/images still backfill).

We deliberately **don't** pre-skip on "the idea already has a judgment from this
guide." That guard was source-coarse: an idea carrying a Michelin Green Star (or a
weak "Recommended") would never collect its ★★★, because the *source* already matched
even though the *kind* didn't. Since the hop runs once per idea (the `enrichedAt`
gate) and the record is idempotent on the full triad, re-following is cheap and can't
double a rating — so the value-blind skip wasn't worth the missed judgments.

### 4. Crawl-sprawl guards

- **At most one link followed**, ever, per idea (the first recognized candidate).
- **Once only** — rides the existing `enrichedAt` gate; the whole hop runs a single
  time, so re-following without a pre-skip guard still fetches the guide at most once
  ever (§3).
- **Best-effort** — a failed or empty guide fetch leaves the idea exactly as the main
  hop produced it; no retry, no `enrichedAt` change beyond the main hop's stamp.
- **No transitive crawl** — links found *on the guide page* are not followed. One hop,
  one level, full stop.

## Why this and not the alternatives

- **Why not follow every guide link?** Crawl sprawl, fetch cost, and false-rating
  risk. The motivating need is one accolade page per place; one hop covers it.
- **Why a path heuristic instead of just "host is a guide"?** A bare host match would
  follow the guide's home page or a city listing — pages with no single place's rating
  to extract, or worse, *another* place's. The detail-shape gate is what makes "follow
  it" safe.
- **Why a plain fetch, not the rendered-DOM browser now?** Most guide detail pages are
  static enough to parse from raw HTML, and shipping the automated rung first tells us
  empirically which guides actually need rendering — so the HITL browser is built
  against a real driver, not a guess (BACKLOG sequencing).
- **Why record evaluations in the enricher at all (it didn't before)?** Following the
  guide link is pointless if we don't write what it says. Recording is idempotent and
  fill-only, so turning it on for the whole merged page (not just the guide link) is a
  consistent, low-risk improvement, not a separate feature.

## Relationship to prior decisions

- **ADR-0016** (source-aware capture): reuses its `ParsedEvaluation` →
  `IdeaEvaluation` bridge and confidence model unchanged; this is the same judgment
  pipeline, fed from a linked page instead of the shared one.
- **ADR-0019 §3** (capture dedup): the (source, kind, value) idempotency is what makes
  a second source of the same rating safe.
- **No schema change.** `ParsedPage.links` is transient; `IdeaEvaluation` already
  exists. Nothing new syncs.

## Consequences

- Restaurants/hotels whose own site links to their guide page now collect that guide's
  rating automatically on the second hop — the reported gap closes.
- `EvaluationRecognizers` and `GuideLinkRecognizer` share one `GuideHosts` definition;
  adding a guide is a one-line table edit that lights up both recognition and link
  following.
- The enricher now contributes judgments, not just facts/images — first time the
  second hop writes `IdeaEvaluation`.
- Pages that need a rendered DOM (JS-heavy, consent-walled, anti-bot) still won't yield
  to the plain fetch; that is the explicitly-deferred HITL-browser rung's job, and this
  rung surfaces which pages those are.

## Open questions

- **Per-guide detail markers beyond Michelin.** v1 ships Michelin's
  `/restaurant`/`/hotel` markers and the generic depth+slug fallback for the rest. If
  the fallback proves too loose or too tight for Forbes / 50 Best / Harper in practice,
  add their markers to the same table — no architectural change.
- **More than one guide link per place.** Out of v1 (one hop). Revisit only if a place
  routinely carries two distinct accolades on one page.
