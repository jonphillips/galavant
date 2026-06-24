# Backlog — granular enhancements

Not milestone-scoped (see ROADMAP.md for those). Running list of refinements
noted in passing, with enough context to act on cold.

## Guide-link enrichment rung + generalized in-app browser (ADR-0016 follow-on, 2026-06-24)

**Automated rung DONE (2026-06-24, ADR-0021, branch `feat/guide-link-enrichment-rung`).**
The four pieces shipped, each tested:

1. **Link extraction** — `ParsedPage.links: [URL]` (absolute http(s), in document
   order, de-duped, fragment-stripped, self-link excluded); `PageParser` harvests
   anchors before the boilerplate strip; `ParseBuilder.addLink`.
2. **`GuideLinkRecognizer`** (pure, `GalavantCapture`) — host ∈ a known guide **and**
   a place-detail path shape: a known detail-path marker (Michelin `/restaurant//hotel/`
   + a slug after it) **or** generic depth ≥ `minDetailDepth` (3, derived from
   locale→region/category→place) with a hyphenated final slug that isn't a section
   keyword. Host list lifted into a shared `GuideHosts` table that `EvaluationRecognizers`
   now also consumes (one definition; the `name` doubles as the `IdeaEvaluation.sourceName`).
3. **Enrichment hop** — `PlaceEnricher.followingGuideLink` follows **one** link via the
   existing `pageFetcher`, parses it (host = guide → ★★★), and folds it in via the new
   pure `ParsedPage.fillingBlanks(from:)` (fill-blanks scalars, append-dedup collections,
   (source,kind,value)-dedup evaluations). The single write now also records the merged
   page's evaluations (`IdeaEvaluation.record`, `.official`) — **first time the second
   hop writes judgments**, not just facts/images.
4. **Crawl-sprawl guards** — at most one link; skipped when the idea already carries
   that guide's judgment; rides the `enrichedAt` once-gate; best-effort; no transitive
   crawl (links on the guide page aren't followed).

**Still NEXT — the in-app browser is the human fallback rung of this same effort — not a separate
track.** The automated hop above does a plain URLSession fetch (the enricher's
`pageFetcher`), which fails on exactly the pages a rendered DOM fixes (JS-heavy,
anti-bot, consent/paywall). A HITL `WKWebView` already ships, but hard-wired to
hours rung-3: `HoursBrowserView.swift` ("Find Hours", `onGrabHours`, stamps
`.unverified`) — it renders JS, holds a session, clears consent walls, scrapes
`document.documentElement.outerHTML`, runs the parser. The recurring theme across
all surfaces is "raw fetch < rendered DOM": the **share extension** gets the
rendered DOM free via Safari JS preprocessing; **hours rung-3** via that WKWebView;
the **app-side enricher** (where this lives) has no rendering — that's the gap.

Sequencing: ship the automated guide-link rung first (handles most static guide
pages, and surfaces which pages actually need rendering), **then** generalize
`HoursBrowserView` into a reusable "load URL → hand back rendered HTML → caller runs
any extractor" component, with hours as one consumer and the guide-link fallback as
the next. Refactor with a real driver, not a speculative general browser. (Bigger
someday vision — "browse to any place, tap capture" as a general entry point — is
out of scope here; keep it to the extraction-fallback role.)

## Hours extraction misses unstructured-markup sites (ADR-0016, 2026-06-23) — DONE

**On-demand ladder DONE (2026-06-23, branch `m6-hours-extractor`).** Shipped the
`HoursExtractor` (`GalavantPlaces/HoursExtractor.swift`) — the on-device LLM
extract-only fallback, mirroring `EvaluationExtractor` (on-device `ModelClient` tier,
strict extract-only prompt, tolerant JSON-object parse degrading to `nil`,
`testValue` → `nil`). Wired into **both** `FieldSupplement` paths via a shared
`resolvedHours(from:)` helper: rung 2 (official-site fetch → `.official`) and the
HITL `applyBrowsedHours` (→ `.unverified`), deterministic structured hours first so a
structured page never pays for a model call. 8 tests (the brewerybhavana-shaped
unstructured fixture + the pure parse degrade). The existing "Find hours" affordance +
HITL browser (`IdeaFormModel`/`IdeaFormView`) now reach unstructured sites with no UI
change.

**Capture-time fallback DONE (2026-06-23).** Two steps shipped together:

1. **Persist deterministic hours at capture** — `CaptureModel.persistCapture` now
   reads `captured.openingHours` (JSON-LD/microdata, already parsed) and writes
   `openingHours`/`hoursProvenance`/`hoursVerifiedAt` onto the `Idea.Draft` (and
   into the merge's `supplemented()` path — fill-blanks-only). Stamped `.official`
   with `now`. The clock is only consulted when there's something to stamp
   (evaluations **or** hours), preserving the original design intent.

2. **LLM fallback deferred to `PlaceEnricher`** — rather than running a second model
   call in the share extension (already at ~120 MB budget from `PlaceIntelligence`),
   the `HoursExtractor` is wired into `PlaceEnricher.enrichIfNeeded` (the app-side
   second hop, M4g) alongside the deterministic pass. Deterministic first; LLM only
   when the parser comes up empty; fill-blanks-only (skipped when the idea already
   has hours from capture). Stamped `.official`. 5 new tests across
   `CaptureModelTests` + `PlaceEnricherTests`.

**Follow-up — the LLM fallback was reaching the model with the wrong text (DONE
2026-06-23, branch `fix/unstructured-hours-excerpt`).** Surfaced on
**das-achental.com/en/es-senz.html**: hours present as free text ("Wednesday –
Saturday 6.30 –11 pm") in a bottom-of-page contact block, but `HoursExtractor`
still came up empty. Root cause was two compounding defects in
`PageParser.textExcerpt`, not the model:
1. **Boilerplate strip was tag-only** (`nav/header/footer/aside`). The site ships
   **zero** semantic landmarks — its whole menu is `<ul><li><a class="single-menu">` —
   so the strip removed nothing and the menu filled the excerpt.
2. **The 1500-char cap then clipped the real content.** The hours sat at char
   offset ~3700, well past the cap; the model only ever saw nav chrome.
Fix: (a) `cleanedBodyText` now also strips by boilerplate class/id and by **link
density** (a block whose visible text is mostly link text is nav, not prose; we
deliberately *don't* strip `class*=menu` — that's a restaurant's food menu); (b) the
single excerpt was split — `textExcerpt` stays a short summary lead (1500, a
deliberate product budget for the summarizer), and a new **uncapped**
`ParsedPage.bodyText` (the full cleaned page) feeds the fact extractors, since
hours/ratings routinely live deep or in a footer. `HoursExtractor` now reads
`bodyText`. (c) Sizing input to a model is the model layer's job, not the parser's:
`OnDeviceModelClient` now **fits the prompt to its own context window**
(`SystemLanguageModel.contextSize` ≈ 4096 tokens — read from the model, not pinned;
reserve system + output, char-budget the rest with a safety margin), so a whole-page
extract or a long chat degrades to a shorter prompt instead of throwing
`contextSizeExceeded`. 6 tests (`PageParserTests` link-density + footer-hours,
`HoursExtractorTests` live-path-reads-bodyText, `OnDeviceFitTests` fit math).
**Still structured-
data-blind only if a site renders hours purely client-side** (no hours in the
fetched DOM at all) — that remains the HITL-browser's job.

## Capture never persists opening hours at all (found 2026-06-23) — DONE

Fixed as part of the "Unstructured-hours capture fallback" above (2026-06-23).
`CaptureModel.persistCapture` now writes the deterministic hours from
`captured.openingHours` onto the idea at save time. See the entry above for full
details.

## On-device Apple Intelligence for capture enrichment (2026-06-17) — DONE

Shipped as **M4d** (2026-06-17, commit e7b0ebe; see ROADMAP). `PlaceIntelligence`,
an injectable `FoundationModels` client in `GalavantPlaces`, refines the parse
before the Apple Maps match via one guided-generation call (`@Generable` +
`@Guide`): clean name, mined city/region, classified `IdeaKind`, de-marketed
notes; availability-gated with silent fallback to the deterministic parser, and
unit-tested with a fixture. Built as described below. Original note retained for
context.

Use the on-device **Foundation Models** framework (Apple Intelligence; iOS 26+, we
deploy 27) to clean and supplement what the `GalavantCapture` parser extracts —
**replacing** the heuristics M4c added, not stacking on them. Surfaced while
capturing real pages (restaurantalouette.dk, forestis.it): structured-source
priority + pipe-tagline clipping + "confident Apple Maps name overrides a chrome
title" get us far, but they're brittle separator/side rules.

Where it earns its place:
- **Clean place name** from a messy chrome title in one general step — handles both
  "Forestis Dolomites | … Hotel in Brixen" → "Forestis" and "Home — Alouette" →
  "Alouette" without guessing which side of the separator the brand is on.
- **Mine city/locality from free-text description** — the real fix for the "Koan"
  miss (Copenhagen only appears in prose), feeding a far better Apple Maps query
  than a bare name worldwide search.
- **Classify `IdeaKind`** when schema.org `@type` is generic (`LocalBusiness`), and
  **summarize** the page into clean notes.

How to fit it without breaking house style:
- **Guided generation** (`@Generable` structs, `LanguageModelSession`) for typed
  extraction — slots into the value-voting as a high-confidence source, or a
  fallback when JSON-LD/microdata are absent.
- Wrap in an **injectable client** (like `PlaceMatcher`/`PlaceSearchClient`) so the
  deterministic parser stays the fallback and it's testable.
- **Gate on `SystemLanguageModel.availability`** — degrade to today's parser when
  Apple Intelligence is off/unsupported.
- Caveats: runs in the share extension (watch the ~120 MB budget — model is a
  system resource but sessions cost), few-second latency (fine behind the
  "Reading page…" spinner), non-deterministic (hence injectable for tests). New API
  past Claude's training cutoff — check current Foundation Models docs and the
  Xcode `swiftui-*` skills before implementing.

## Codex alignment-review follow-ups (2026-06-16)

Deferred items from `docs/reviews/codex-alignment-review-2026-06-16.md`. The
review's two acted-on items landed already: the filtered swipe-delete bug fix
(`IdeasListModel.deleteIdeas` now takes the displayed array) and the CLAUDE.md
iOS-26→27 correction. The rest, in rough priority order:

- **Regression test for filtered swipe-delete.** The fix is structural (the view
  hands `deleteIdeas` the exact `filteredIdeas` it rendered), but there's no
  automated guard against a future re-wiring. Blocked on test infrastructure:
  the app target has **no unit-test bundle** (only `GalavantSchemaTests` in the
  package + `GalavantUITests`), and a destructive UI test can't be made
  deterministic because there's **no DB-reset launch arg** (the app-group DB
  persists across launches; `--reset-identity` only clears `currentPlannerID`).
  A real regression test wants one of: an app unit-test target exercising
  `IdeasListModel`, or a `--reset-database` arg + a seeded UI test that filters
  to one region (e.g. New York) and verifies the swiped row — not the
  global-alphabetical-first idea — is the one deleted.

- **Complete ADR-0008 sync-dedup hardening.** The picker/bind UI shipped, but the
  ADR's other half is not implemented and code comments imply otherwise. (1)
  `IdeaInterest`/`IdeaTag`/`TripRegion` need a schema-level **dedup-on-read**
  helper that deterministically collapses logical duplicates (lowest-UUID-wins),
  with all read models calling it instead of rebuilding "first wins" dicts
  locally (`IdeasListModel.swift:145`, `TripPlanningModel.swift:226`); add
  seeded-duplicate tests. (2) `TravelParty.ensureDefault` + `Planner.create`
  should implement the ADR's **prefer-shared/non-empty party, clean the empty
  stray** rule rather than "first party by UUID." Slated for the M2 tail per the
  ADR. Adjacent to the existing "Planner identity feels fly-by-night" item.

- **Schedule doc-drift sweep.** — DONE (2026-06-23). Updated `docs/PRODUCT.md`,
  `docs/STYLE.md`, and `docs/decisions/0004-pull-based-trip-membership.md` to the
  V3 vocabulary (`unscheduled / day / daypart(DayPart) / timed`, calendar dates
  derived from the trip's start, `.exact` dropped). `docs/ROADMAP.md` was already
  corrected (the M3c entry notes "drops V2's `.exact`"); the review's other
  `.exact` mentions (`trip-time-model.md`, `recovered-requirements.md`) are
  correct history and left as-is.

- **UUID dependency-control for *new* schema ops.** Operations call `UUID()`
  directly (`TripOperations`, `PoolOperations`, `Tag`, `TripRegion`, `IdeaTag`).
  Don't churn working code, but new vertical slices should accept IDs as args
  (model supplies a dependency-controlled `@Dependency(\.uuid)`) rather than
  spreading direct `UUID()`.

- **Standardize derived bindings.** — DONE (2026-06-23). `TripPlanningView`'s two
  sites were already gone. The `TripPlanningSheets` "Show visited" toggle now uses
  `@Bindable var model` + `$model.includeVisited` (the codebase's established
  idiom). The `RegionManagerView`/`TagManagerView` rename alerts drive off an
  optional *struct* payload → bool — which `@Bindable` and the current
  SwiftUINavigation case-path bindings (enum-only) don't cover — so they now use a
  small reusable `Binding.isPresent()` helper
  (`Galavant/Navigation/Binding+Present.swift`), the local pattern to copy.

- **Swallow `CancellationError` on one-shot model reads.** — RESOLVED, no code
  change needed (verified 2026-06-23). The pinned `withErrorReporting`
  (xctest-dynamic-overlay) already catches `CancellationError` and ignores it in
  every overload (sync + async — `ErrorReporting.swift` `catch is CancellationError`).
  Both `IdeaFormModel` and `TripFormModel` wrap their `.task` reads in it, so a
  cancelled read is silently swallowed, never reported. The review's concern
  predates this library behavior (or assumed it reported all errors).

- **Document `-skipMacroValidation` for headless verification.** First Xcode CLI
  build stops on macro re-approval; `xcodebuild … -skipMacroValidation build`
  succeeds. Worth a line in CLAUDE.md's toolchain/verification notes (does not
  replace human Xcode macro approval).

- **jon-platform shared-doc refinements (not galavant-local).** The review's last
  section proposes folding five rules into `~/code/jon-platform` (displayed-
  collection delete/reorder rule; split-view nested-NavigationStack clarification;
  UUID-generation nuance; one-shot-read cancellation note; macro-validation CLI
  note). These belong in the house knowledge base, not here — apply there.

## Capture form should be search-first and auto-populated (from Jon, 2026-06-12) — DONE

Implemented 2026-06-16. The New Idea form now **leads with the place search**
(`Section("Place")` at the top); picking a result drives the rest. New schema-side
pure mapping `IdeaKind(pointOfInterestCategoryRawValue:)` (keyed on MapKit's stable
`MKPOICategory*` raw strings so the schema package stays MapKit-free and fully
tested — `IdeaKindTests`; unknown/future categories fall back to nil → Unspecified).
A new SPM module **`GalavantPlaces`** holds the search boundary: a `Place` value
type (the hit + kind/url/phone/address), an injectable `PlaceSearchClient`
(`@Dependency(\.placeSearch)`, MapKit isolated behind it), and the view-facing
`PlaceSearchModel` (query/results/debounce). `IdeaFormModel.setLocation(_:)` fills
name/kind/link **only when still empty** (confirm-and-tweak), refreshing
address/phone/region as facts about the place. New `address`/`phone` columns on
`Idea` (additive migration); the detail view surfaces address + a tappable `tel:`
phone row. Uses the iOS 26 `MKMapItem.location`/`address`/`addressRepresentations`
API (`placemark` deprecated) — no `Contacts`/`CNPostalAddressFormatter` needed.
`PlaceSearchModelTests` overrides the client with a fixture (no MapKit/network) —
the first feature-model test, establishing the package-home pattern for
dependency-backed models (the app target has no test bundle). **Deferred:** the
*neighborhood* subtitle (we store full address, not parsed sublocality — still
gated here). Original note below.

The New Idea form currently leads with Name, then a Location section midway
down. It should **invert**: location search at the *top*, driving the form. You
search a place, pick it, and the rest fills in from what MapKit returns:

- **Kind** ← `MKMapItem.pointOfInterestCategory` mapped to `IdeaKind`
  (e.g. `.restaurant` → `.food`, `.museum` → `.museum`, `.hotel` → `.stay`).
  Build the category→kind table; fall back to unspecified.
- **Link** ← `MKMapItem.url` (the place's website).
- **Address / phone** ← `MKMapItem.placemark` / `phoneNumber` (we currently
  only keep locality as `regionName`; capture more).
- Name is already auto-filled; the rest of the form becomes confirm-and-tweak.

This is the on-device cousin of the V1 server enrichment (scraping-enrichment.md)
— MKMapItem is itself a rich enrichment source we're underusing. Pull forward
into M2 capture polish or fold into M4.

## Location search robustness (from Jon, 2026-06-12) — DONE

Fixed 2026-06-16. Root cause: `MKLocalSearchCompleter` biases to the device's
location (Cupertino in the sim) and handles combined "<name> <city>" fragments
poorly, so Copenhagen's Noma never surfaced. Switched `PlaceSearchClient` to
`MKLocalSearch` with a **natural-language query** over a **world-wide region**
(`MKCoordinateRegion(MKMapRect.world)`) — what Maps uses; "Noma Copenhagen" now
resolves. Debounced (300 ms) with in-flight cancellation since `MKLocalSearch` is
throttled, and the last results stay put on throttle/cancel rather than flashing
empty. Bonus: each hit carries its full `MKMapItem`, so picking is synchronous (no
second resolve round-trip). **Note:** a bare 1–2 word name with no city is still
inherently ambiguous worldwide — results sharpen as the user adds the city.
Original note below.

"Noma Copenhagen" returned no results, while "Tivoli Gardens" worked.
Hypothesis: a combined `"<name> <city>"` query underperforms in
`MKLocalSearchCompleter` versus searching `"<name>"` with a **region bias**
(set `completer.region` to the area of interest). Investigate: bias the
completer by the user's current map region (or last-used region), and/or split
trailing city tokens. Also confirm `resultTypes`/`pointOfInterestFilter` aren't
over-narrowing.

## Planner identity feels fly-by-night (from Jon, 2026-06-12)

The name-only "Who are you?" prompt feels flimsy; Jon wants a stronger key
(email on file, collision-resistant). Resolution direction recorded in
**ADR-0008 → "Future: back planner identity with the CloudKit participant"**:
derive identity from the accepting Apple ID (unique key + name/email when
consented), `displayName` as editable override. Blocked on the M5 real-device
share-accept flow. Cheap interim option: optional typed `email`/subtitle on
`Planner` for picker disambiguation.

## Consolidate management UIs into a settings/"You" area (from Jon, 2026-06-12)

Tag and Region management currently hang off the filter menu (Manage Tags… /
Manage Regions…). That's a temporary home — these (plus planner identity/
switching and sync health) should migrate into a dedicated settings or "You"
nav section, not be buried in the filter. Punted for now; tracked here. Likely
lands when the third nav section ("You"/Account) is built (M5-ish).

## Multi-select tag assignment on Ideas (from Jon, 2026-06-13)

The data model already supports many tags per idea (IdeaTag join), but the form
adds them **one at a time** (type-and-add with autocomplete). Jon wants a
**multi-select tag picker** (confirmed 2026-06-13): a scrollable list of all
existing tags with checkmarks, toggling several on/off at once. **A dedicated
screen is acceptable** (push from the form's Tags section → tag-picker screen →
back). Keep the type-to-create-new-tag path available there too. The current
one-at-a-time add stays as the inline quick path; this is the "manage many"
surface. Likely reuses TagManagerView's list shell.

## Export itinerary to Apple Calendar / iCal (from Jon, 2026-06-13)

Once a trip is **dated**, let the app populate a calendar with its scheduled
stops via **EventKit** (`EKEvent`s in a dedicated "Galavant: <trip>" calendar,
or `.ics` export for sharing). The M3c data model is already shaped for this:
`Trip.date(forDay:)` derives the calendar date for each day number, and the
`Schedule` facade gives the time — `.timed` → exact `EKEvent` start/end,
`.daypart` → an all-day-ish event anchored at `DayPart.sortHour` (the
representative hour we already sort by), `.day` → all-day event. Undated trips
have nothing to export (day-relative only). Considerations: re-export should
reconcile (update/delete) rather than duplicate; needs the Calendars privacy
permission; likely a per-trip "Add to Calendar" action. Bigger than a one-liner
— a small feature, post-M3 (fits the M5 polish/integration band).

## Booked reservations as absolute, pinned stops (from Jon, 2026-06-13)

A confirmed reservation (OpenTable, hotel, timed entry) is an absolute fact —
nailed to a calendar date, must **not** slide when the trip's start date moves,
unlike a day-relative *planned* stop. M3c trimmed V2's `.exact(Date,…)` from
`Schedule` (day-relative is deliberate — trip-time-model.md §2), but did **not**
preclude this. Fix is additive: an optional `TripIdea.pinnedDate: Date?` plus
booking metadata (confirmation #, booking URL, party size, booked-vs-planned)
that locks the stop to its date and re-derives `dayNumber` if the start slides.
Land with **M4 capture** (when a share/OpenTable import creates one); pairs with
the "reservable-from" booking-window work. Full rationale + decision in
**docs/trip-time-model.md §4**.

## Trip header image — "romance" (from Jon, 2026-06-14)

The trip screen looks stale; Jon wants a **selectable header image** so a trip
*feels* like its place ("feel like Copenhagen"). Worth the vertical space.
Precedent: V1/V2 GalavantLibrary `UnsplashSearch` (already a tested SPM module —
docs/MINING.md M5 row) let you pick from an image service. Plan: a per-trip
image (search Unsplash by destination/region name, or pick from Photos), shown
as a large header on the planning screen behind the title. Considerations:
needs an Unsplash API key (confirm the service/free tier still exists, else
swap source) + attribution; store the **choice** (URL/asset id + author) on
`Trip` and CloudKit-sync it; cache the bitmap locally (don't sync blobs). This
is the romance/polish pass — ROADMAP already lists "Unsplash header images" under
M5; this elevates it. A focused feature, not a quick tweak — do it as its own
slice.

## AI assistant / chat (from Jon, 2026-06-13)

A larger future theme, not yet milestone-scoped: an in-app conversational
assistant (Claude API — see CLAUDE.md model guidance) layered over the pool +
trips. Plausible jobs, roughly in value order: **capture/enrichment** ("add the
restaurant from this link", parse a pasted blog list into ideas — overlaps the
M4 scraping pipeline), **planning help** ("draft a 3-day Copenhagen itinerary
from my shortlist", "what's near Tivoli I've saved?"), and **Q&A over the pool**
("which Denmark food ideas haven't we visited?"). Wants a real design pass:
where it runs, what context/tools it gets (read the SQLite pool? call the
schedule ops?), cost, and the two-person-household privacy posture. Park here as
a direction; revisit after the core loop (M3/M4) is solid.

## AI pool-stocking via App Intents — discovery → candidate ideas (from Jon, 2026-06-22)

> **Designed as ADR-0018 + M6e (2026-06-23).** The discovery-pipeline first slice
> below is now settled in `docs/decisions/0018-ai-pool-stocking-discovery.md` with an
> execution brief in `docs/M6-EXECUTION.md` (M6e): one grounded `complete()` web-search
> call → JSON candidates → reuse `PlaceMatcher`/`DiscoveryDedup` → candidate Ideas;
> frontier-only/BYO-key; slice-0 spike gates discovery quality. The `findPlaces`
> App-Intent verb vocabulary (the rest of this entry) remains the later composable
> payoff, not the v1 slice.

The concrete, bounded first slice of the "AI assistant / chat" theme above: not
open chat, but a small **action layer**. The organizing principle (from the
2026-06-22 design chat) — **AI stocks and understands the pool; it never decides
the trip.** PRODUCT.md already says "a trip never automatically contains anything";
that explicit-**pull** boundary is exactly where AI stops. AI may fill the junk
drawer aggressively and help with the *mechanical* parts of scheduling, but the
taste calls (what's worth pulling, what makes the trip) stay Jon's. Jon's own best
example: *"find me all the 2- and 3-star Michelin restaurants in the Loire and
create ideas for them"* — research that **stocks** the pool, where pulling is still
manual, so it feels safe.

**Architectural fit (no new UI concept):** ADR-0013 already distinguishes
**candidate vs. pulled** pins. AI-generated ideas land as **candidates** — Jon
dispositions them on the map exactly as he does today. AI is just a third,
tireless source feeding the pool alongside share-extension capture and manual
entry.

**The discovery pipeline (generalizes the Michelin case).** This is *discovery*
(query → a set of candidate places), distinct from today's *enrichment* (fill in
an already-known place). Steps:
- Query + region → a candidate set ("2–3⭐ Michelin in the Loire"; "natural wine
  bars in Lisbon"; "playgrounds near our Rome stops").
- Each candidate becomes a **candidate `Idea`**, auto-bucketed into the right
  `MapRegion`, auto-`IdeaKind`/auto-tagged, enriched on-device via the existing
  `PlaceIntelligence` (`FoundationModels`) + `GalavantPlaces` search stack.
- **Dedup against the pool is the non-obvious essential** — don't re-add the
  places already saved; flag near-matches. Reuse the existing place-matching in
  `GalavantPlaces` (`PlaceMatcher`).

**App Intents — two distinct payoffs (don't dismiss because we're not on the App
Store):**
- *Personal friction reduction.* "Hey Siri, add this to our France ideas";
  Spotlight-search the pool from the home screen; a geofence Shortcut that opens a
  region's ideas on arrival; a glanceable "today's stops" widget.
- *The substrate (the real reason).* Define a small, safe **verb vocabulary** as
  App Intents over the tested schema core — `findPlaces`, `createIdea`,
  `scheduleStop`, `rateIdea` — and expose `Idea`/`Trip`/`Region` as `AppEntity`s.
  Then the Michelin sentence isn't a bespoke feature; it's a model decomposing the
  request into `findPlaces` ∘ `createIdea`. Build the action layer once; natural
  language orchestrates it. This is what makes the whole pool-stocking theme
  *composable* rather than one-off.

**Open design questions (need a real pass):**
- **Discovery quality is the main risk.** Does "all Michelin in the Loire"
  actually return the right set? Worth a **throwaway spike** before committing —
  if the candidate set is wrong/incomplete, the feature is noise. On-device
  `FoundationModels` is great at *structuring* a known place but is not a
  web-search index; discovery likely needs web fetch (in-app, no server per
  ADR-0001) and/or the Claude API — that's the where-it-runs/cost call the AI-chat
  entry already flags.
- **Live data** (real-time hours, availability, reservations) bumps the no-server
  constraint — feasible via on-device web fetch in enrichment, but flakier; keep it
  out of the first slice.
- **Two-person privacy posture** — same as the AI-chat entry.

**Suggested first slice:** the discovery → candidate-ideas pipeline behind a
`findPlaces` App Intent + a simple in-app entry (region-scoped themed search,
results reviewed as candidate pins on the pool map). Spike discovery quality
*first*; only then wire `createIdea` and the dedup pass.

**Adjacent bets surfaced in the same chat** (separate entries when they ripen, not
this slice): **match *prediction*** — extend the his/hers `Interest.standing`
projection from a lagging tally to a *predicted* match for unrated ideas (the most
differentiated long-term bet, unique to a two-person app); **semantic pool search**
("that cozy waterfront place we saved") via on-device embeddings; **latent-trip
clustering** (surface a someday-Jutland from 14 clustered ideas).

## Drag itinerary stops between days / out of the bucket (from Jon, 2026-06-13/14) — BLOCKED (Xcode 27 beta 1)

Attempted and **backed out** 2026-06-15 (M3d follow-up): **List drag-and-drop is
broken on Xcode 27 beta 1** — every drop times out (`Gesture: System gesture gate
timed out`), the lift works but the drop never lands. Tried three different `List`
drop surfaces, all failed on device: (1) `.dropDestination` on the **section
headers** (don't register as drop targets — a real `List` limitation, not just
beta); (2) the iOS 27 **reorder container** (`.reorderable(collectionID:)` +
`.reorderContainer(for:in:)`, the Apple-sanctioned path) — flaky on this beta,
matching the **Someday reorder** known-issue; (3) `.dropDestination` on the
**rows** + empty-day placeholder (the standard, usually-reliable surface) — also
times out. Three surfaces failing on one beta points at the beta's DnD subsystem,
not our code. Reverted to keep the tree clean; the `StopMenu`'s Move-to-Day /
To-Be-Scheduled fully covers the function meanwhile. See docs/KNOWN-ISSUES.md.

**Revisit on a later beta.** If row/reorder DnD still fails, the durable fix is to
render the full itinerary as a `ScrollView`/`LazyVStack` (no `UICollectionView`
interception) rather than `List` — a bigger change, deferred until it's worth it.
The model ops are trivial to re-add (`schedule.onDay(n)` / `scheduleUnplaced`).
Original note below.

M3c places/reorders stops via a "Move to Day"/"Set Day" menu + the Add-Stop
sheet. Jon wants stops **draggable across day sections** directly — *and* (added
2026-06-14) **dragging items out of the "To Be Scheduled" bucket onto a day**.
Both are the same gesture: drop target → day number → `TripIdea.schedule(_.onDay(n))`
(or `scheduleUnplaced` to drop back into the bucket). Needs cross-section drag
(the M3b `reorderable()`/`reorderContainer` is single-collection). Within-day
reordering is moot (stops auto-sort by time), so this is purely "drop onto
another day / the bucket." Fast-follow; the menus cover the function until then.

## Grow the Itinerary stop detail into a richer screen (from Jon, 2026-06-14) — PARTLY DONE

First growth landed 2026-06-15 (M3d follow-up): the detail now opens with a static
thumbnail **map** of the stop's pin, an **Open in Maps** handoff (maps.apple.com
URL), and an **On the Itinerary** section (day + time, or the bucket) via
`stopContext` (nil for a plain pool idea). **Still deferred** (the reasons to
break out of the panel into full-screen): **MKDirections travel time** from the
previous stop, **opening hours**, and **booking** — revisit once that data exists
on the model. Original note below.

The shared read-only `IdeaDetailView` ships as an **in-panel drill-down** (M3d
follow-up): `TripDetailContent` swaps in the detail as an opaque overlay keyed on
`detailIdeaID` (with its own back header) *within the panel itself* (the iPhone
bottom sheet / the iPad right column) rather than presenting a sheet over the map —
the map stays visible the whole time. (Not a nested `NavigationStack`: one inside
the iPad `NavigationSplitView` detail stack made the trip push pop straight back.)
The
Trip Ideas list pushes on row tap; the Itinerary keeps row-tap = stop selection
and pushes from a trailing info-circle button (its own hit target, beside the
`StopMenu`). Deferred follow-up: grow the **Itinerary** stop detail with richer
per-stop context (map of the stop, MKDirections/travel time, opening hours,
booking) — at which point it may want to break out of the panel into a
full-screen presentation. Revisit once that content exists.

## Reveal a selected stop above the iPhone sheet (from Jon, 2026-06-15) — DONE

Implemented 2026-06-15 (M3d follow-up). `MapFraming.reveal` gained a `bottomInset`
(the southern fraction the sheet covers); the canvas feeds it a *measured*
sheet-height ÷ map-height ratio (via `onGeometryChange`, capped at 0.6) and
re-reveals when it changes, so a pin the rising sheet would swallow pans up into
the clear. iPad (inset 0) is unchanged. 3 new MapFraming tests. Original note below.

Selecting a stop pans its pin on screen with the **minimum** move, keeping the
current zoom and not re-centring (`MapFraming.reveal` + `TripCanvasMapView`
`revealStop`, shipped). It pans against the **full** map region, which is exact on
iPad (the detail is a side column, map unobscured) but imperfect on iPhone: the
bottom sheet covers the lower map, so a stop revealed near the bottom edge can land
*behind* the sheet — geometrically on screen, visually hidden. Fix: treat the
sheet-covered height as a **bottom inset** on the reveal box (pan the pin into the
unobscured area above the sheet). Needs the sheet's current height plumbed from
`TripPlanningView` (it owns `sheetDetent`) into the map; system detents
(`.medium`/`.large`) are only approximable, so a measured/inset approach is better
than mapping detents to points. Costs a bit more than the strict minimum pan, by
design (keep the pin out from under the sheet).

## Itinerary completion model: assume-done + a "now" marker (from Jon, 2026-06-13) — PARTLY DONE

The **"now" marker shipped 2026-06-20** (commit 5353650): a you-are-here divider
on active dated trips (`TripItineraryView` + the `TripPlan` core), so the current
moment's place in the itinerary is shown. **Still deferred:** the inferred
completion / **trip-level done→visited rollup** (flip a past trip's non-skipped
scheduled ideas' `visited`) — the `TripIdea.markDone` op + test remain the
mechanism; only the trip-level trigger is unbuilt. Original note below.

Jon removed per-stop **Mark Done** from M3c — "no one wants to mark Done on an
itinerary; just assume they did it." Skipped stays (an explicit negative signal).
So completion should be **inferred**, not tapped: once a trip's day/time has
passed, its non-skipped stops are effectively done, and a **"you are here / now"
highlight** should show where the current moment falls in the itinerary (design
TBD — Jon unsure how yet). Consequence for the **done→visited** feedback loop
(ADR-0004): it moves from a per-stop action to a **trip-level rollup** — when a
trip is past/marked complete, flip its scheduled ideas' `visited`. The
`TripIdea.markDone` op + test stay (the mechanism); only the UI trigger changes.
Design item; pairs with weather/“now” work on the trip canvas.

## Freeform itinerary stops not tied to an idea (from Jon, 2026-06-13) — DONE

Shipped 2026-06-20 across three slices per **ADR-0010** (commits b3a1015 /
61d900a / d3f4008): (1) schema migration + read-model core — `TripIdea.ideaID`
made optional with `inlineTitle`/`inlineNote` columns, the read-model resolving
each stop into a `StopContent` enum (`.idea` / `.freeform`); (2) stop ops re-keyed
from `Idea.ID` to `TripIdea.ID` so freeform stops work end-to-end; (3) the write
path — per-section "+" and an Add Custom Stop flow. Freeform stops are born
`.scheduled` and carry no coordinate (so no map pin / travel-leg, handled for
free). One record, one itinerary pipeline. See ADR-0010 for the full rationale
(incl. why not a sibling record).

## Accommodations (from Jon, 2026-06-13) — DESIGNED

Design settled in **ADR-0011** (2026-06-20): a sibling **`TripStay`** record (one
FK → `Trip`, loose optional `ideaID`, freeform-capable, `checkInDay`/`checkOutDay`
+ optional `"HH:mm"` times), *not* a `Schedule` case — the span inverts ADR-0010's
one-record logic. Itinerary = a home-base chip on every covered day header +
check-in/check-out timeline rows (new `ItineraryItem.checkIn`/`.checkOut`); canvas
= a distinct off-sequence base pin, unnumbered, off the day polyline. Stays are
born on the trip (not pulled); overlap is allowed-but-flagged. Deferred seams:
booking metadata/`pinnedDate` (trip-time-model §4), per-day-region *driving*
(display-only for now), a "Stays" summary band, hotel-anchored routing.
Implementation not yet started. See ADR-0011 for the full rationale (incl. why a
sibling record, not a `TripIdea` extension).

## Portfolio extraction seams: parser engine + image processing (from Jon, 2026-06-14)

Two capabilities coming up have a life beyond Galavant (Jon's wider app
portfolio, e.g. a future recipe manager): **web capture/parsing** (M4) and
**image storage tools** (M2 images). Decision: **isolate now, extract later** —
do *not* stand up a shared package against a single consumer (premature
extraction calcifies the wrong API). The expensive mistake is *entanglement*,
not late extraction; so build both as cleanly-isolated targets in the local SPM
package with strict boundaries, and lift to a neutrally-named shared package only
when a **second real app** needs them and both consumers' requirements are
visible (the "reason" CLAUDE.md requires for a new package).

Boundary discipline to enforce while building:

- **Parser engine = `HTML/text → generic structured struct`.** The portable unit
  is the *pure transform* (schema.org/JSON-LD/OpenGraph → normalized result), not
  "in-app browser." The browser is just one *source* of HTML (share extension and
  server fetch are others). Engine must never import SwiftUI/CloudKit and never
  see `Idea`/`Trip` — domain mapping (generic result → `Idea`) stays in the app.
  This also makes it unit-testable with zero browser/network. Aligns with the M4
  enrichment pipeline (docs/scraping-enrichment.md).
- **Image tools = split processing from storage.** Resize/compress/thumbnail are
  pure functions over `Data`/images — maximally portable, the clean extraction
  candidate. *Storage* ("dedicated table, CloudKit-synced, no S3" — ADR-0009)
  is stack-specific; it travels only if the other app also uses
  SQLiteData+CloudKit. Keep processing free of any persistence import.
- **Naming (ADR-0006):** a portfolio library needs a *neutral* name — no app
  domain in it. V2's `GalavantLibrary` was within-app and Galavant-named; that
  pattern is wrong for a cross-app package. Decide the name when the second
  consumer is real, not now.

No code action yet — this is intent to honor when M2 images and M4 capture get
built, so the eventual extraction is a rename-and-move rather than surgery.

## Icon enum — central SF Symbol vocabulary (from Jon, 2026-06-14) — DONE

Implemented 2026-06-14 (`Galavant/Design/Icon.swift`, own commit). Swept the
chrome literals across the 17 listed files to `Icon.x.label(…)` / `.image` /
`.systemName`. Deliberately left as-is: domain-enum `systemImage` properties
(`IdeaKind`, `DayPart`, `IdeasScreen.Mode`), interpolated generic helpers
(`AddIdeasSheet.addToggle`, the off-state filter glyph), and fill/outline toggle
pairs where the lit glyph has no role case (`star`/`star.fill`,
`calendar.badge.checkmark`, `heart`/`heart.fill`). Original draft retained below
for reference.

Adopt a single semantic icon enum (V2 had one; reviewed 2026-06-14). Today the
app has ~65 `Image(systemName:)`/`systemImage:` call sites across 26 distinct
stringly-typed symbols; a typo renders *blank*, never fails to compile. The enum
names each symbol by **role** (`.edit`, not `"pencil"`) so a glyph swaps in one
place and call sites read as intent. Lighter/stricter than V2's (which only got
partial adoption): no dependency, role-named, enforce "no raw `systemName:` in
chrome" in review. Domain enums (`IdeaKind`, `DayPart`) keep their own
`systemImage` — this is for shared UI affordances only.

**Do this as its own commit, after M3d is committed** (don't fold into M3d).
Lives in `Galavant/Design/Icon.swift` (new dir). Ready-to-go draft (every symbol
below is already in use, so all are known-valid):

```swift
import SwiftUI

/// The app's icon vocabulary: every SF Symbol used in chrome/actions, named by
/// *role* not glyph, so a symbol swaps in one place and call sites read as intent
/// (`Icon.edit`, not `"pencil"`). A mistyped symbol can't reach a view — the case
/// is the only spelling. Domain enums (`IdeaKind`, `DayPart`) keep their own
/// `systemImage`; this is for shared affordances.
enum Icon {
  // Create / edit / destroy
  case add            // primary add (toolbar / list)
  case addInline      // inline "create this" affordance
  case defineRegion   // create a map region
  case edit
  case delete         // permanently remove
  case remove         // take out of a set (e.g. a tag)
  case skip           // mark a stop skipped
  case revert         // move back / undo a placement

  // Status / controls
  case checkmark      // selected / confirmed
  case disclosure     // row chevron
  case filterActive   // filter control, engaged
  case manage         // manage / adjust (regions, tags)
  case sidebar

  // Scheduling
  case calendar       // generic / "nothing scheduled"
  case schedule       // place a stop on a day
  case unschedule     // pull a stop off its day
  case toBeScheduled  // committed but dayless

  // Places
  case map
  case location       // a stop/idea that has coordinates

  // Domains / sections
  case trips
  case ideas
  case shortlist
  case interest
  case tag
  case travelParty
  case emptyPool      // empty idea pool

  var systemName: String {
    switch self {
    case .add: "plus"
    case .addInline: "plus.circle"
    case .defineRegion: "plus.viewfinder"
    case .edit: "pencil"
    case .delete: "trash"
    case .remove: "minus.circle.fill"
    case .skip: "xmark.circle"
    case .revert: "arrow.uturn.backward"
    case .checkmark: "checkmark"
    case .disclosure: "chevron.right"
    case .filterActive: "line.3.horizontal.decrease.circle.fill"
    case .manage: "slider.horizontal.3"
    case .sidebar: "sidebar.left"
    case .calendar: "calendar"
    case .schedule: "calendar.badge.plus"
    case .unschedule: "calendar.badge.minus"
    case .toBeScheduled: "calendar.badge.clock"
    case .map: "map"
    case .location: "mappin.circle.fill"
    case .trips: "suitcase"
    case .ideas: "lightbulb"
    case .shortlist: "star"
    case .interest: "heart.fill"
    case .tag: "tag"
    case .travelParty: "person.2"
    case .emptyPool: "tray"
    }
  }

  /// The raw glyph (icon-only buttons, decorative images).
  var image: Image { Image(systemName: systemName) }

  /// A titled label — the common `Label("…", systemImage:)` shape.
  func label(_ title: LocalizedStringKey) -> Label<Text, Image> {
    Label(title, systemImage: systemName)
  }
}
```

Sweep when applying: replace the literals in these files —
`AppContainer`, `AppScreen`, `IdeaFormView`, `IdeasScreen`, `IdentityView`,
`InterestView`, `PoolMapView`, `RegionManagerView`, `StopMenu`, `TagManagerView`,
`TripCanvasMapView`, `TripDetailContent`, `TripFormView`, `TripIdeasView`,
`TripItineraryView`, `TripPlanningSheets`, `TripsScreen` — using
`Icon.x.label("…")`, `Icon.x.image`, or `Button("…", systemImage: Icon.x.systemName)`.
NB: don't name it so it collides with SwiftUI's `Label<Title, Icon>` generic —
keep the convenience on the enum (above), don't add a `Label where Icon == Image`
extension. Optional follow-on: if/when the app gets a unit-test target (or this
moves to a package module), add a test asserting `UIImage(systemName:) != nil`
for every case to catch future typos at test time.

## Filter reminder above the list (from Jon, 2026-06-12) — DONE

Show active filter settings in small text above the filtered list. Implemented
2026-06-12 (filter summary bar via `safeAreaInset`).

## Itinerary panel cleanup: one time vocabulary + drop redundant city (from Jon, 2026-06-15) — DONE

Implemented 2026-06-16 on branch `m3e-ideas-trip-awareness`. **(a) One time
vocabulary** — the itinerary stop's time (the `StopMenu` trailing label, the only
place the vocabularies mixed; the Ideas tab shows just a calendar icon and the
stop detail keeps the verbose `Schedule.display`) now renders by one rule: a
`.timed` stop shows its clock range in **mono + primary** (a hard constraint), a
`.daypart` shows the daypart in secondary (a soft bucket), and a bare-`.day` stop
drops the "Anytime" word for a faint **clock glyph** (`Icon.timeOfDay`) that still
opens the time menu. **(b) Drop the redundant city** — `PlanningRow` gained a
`Subtitle` mode; the Itinerary and Trip Ideas tab pass `.category` (the idea's
kind, e.g. "Museum"), while the Add-Ideas sheet keeps `.region` (the wider pool,
where the city disambiguates). Presentation-only, no schema/test change.
**Deferred (the mockup's unmet half — no data yet):** the subtitle's *neighborhood*
part (we store only locality/city as `regionName` — gated on the search-first
capture work that captures `placemark` sublocality) and the day headers' *area*
label (gated on per-day region stops, deferred in M3). Original note below.

*Leads the design-review batch below; explored with mockups in the 2026-06-15
design session.* The trip itinerary list currently mixes time vocabularies in one
column — meal/daypart anchors (`Morning` / `Lunch` / `Afternoon` / `Anytime`)
sitting next to exact clock ranges (`19:00–21:00`) — which reads as three systems.
Settle on **one spine**: the existing `DayPart` dayparts (Morning / Midday /
Afternoon / Evening) as the default, with an **exact clock time shown only when the
stop is `.timed`**, rendered in **mono** so a pinned time reads as a hard constraint
vs. a soft bucket. Drop `Anytime` as a visible label (it's just "no daypart set").

Separately: every stop row repeats the trip's city ("Tokyo") underneath — pure noise
inside a single-destination trip. **Strip the city subtitle in single-destination
contexts** (itinerary list AND the trip Ideas tab) and put **neighborhood / category**
there instead (signal, not the city we already know). Rule of thumb: show the city
only where it disambiguates (the global pool), hide it where context supplies it
(inside a trip). **Not in scope:** stop drill-down detail content — being revised in
a parallel session, leave it alone. Refs: `Schedule` facade / `DayPart`
(trip-time-model.md), `TripItineraryView`, `TripIdeasView`. **Mockup:**
`docs/mockups/itinerary-cleanup.html`.

## Ideas list trip-awareness: active-trip capsules + cell trip-badges (from Jon, 2026-06-15) — DONE

Implemented 2026-06-15 on branch `m3e-ideas-trip-awareness`. **(a)** A capsule row
tops the Ideas screen — "All" plus the lifecycle-derived in-play trips
(`Trip.activeCapsules`: every dated + targeted, plus the top-of-backlog someday;
the someday slot approximates "most-recently-touched" by backlog rank since `Trip`
has no touch timestamp). Tapping a trip scopes the pool to that trip's `TripRegion`
lens (reusing `poolFiltered`) and turns each row into a pull/shortlist surface for
*that* trip (the considering/star toggles, mirroring the Add-Ideas sheet, over the
tested `TripIdea` ops); the filter menu's Region submenu hides while a trip is
active. **(b)** In the "All" pool each cell shows a derived `IdeaTripBadge` —
most-actionable across joins (scheduled > upcoming > someday > visited), free ideas
blank; certainty-stage tint (dated blue / targeted orange / someday gray) shared by
the capsule dot. New pure cores `IdeaTripBadge` + `Trip.activeCapsules` with tests.
**Deferred:** the mockup's "match" pill belongs to the next item (his/hers rating +
match), not built here; "Visited" badge drops the year (no visited-date on `Idea`).
Original note below.

*Wants to land soon after the itinerary cleanup.* Two related additions that make the
eternal pool aware of the 2–3 trips actually in play.

**(a) Active-trip capsules.** A row of pills at the top of the Ideas screen = the
in-play trips (Dated + Targeted, plus the most-recently-touched Someday). Tapping a
capsule scopes the pool to **that trip's lens** — the region-scoped pool primed to
pull/rate *for that trip* (PRODUCT.md:17 — pulling happens in the trip's lens; two
Virginia trips are two capsules over one region, so "pull onto which?" is never
ambiguous). Intent: the Ideas screen becomes **dual-purpose** — a launchpad (jump
into an active trip) on top, the firehose below; don't let it drift into "just another
filter bar." Derive the capsule set from the **trip certainty lifecycle**
(recovered-requirements §1: someday→targeted→dated), *not* raw filter MRU (which
lingers stale).

**(b) Cell trip-badges.** Each idea cell shows a **derived** badge of its trip
association — *scheduled* / *on an upcoming trip* / *held in a someday* / *visited* —
projected from the `TripIdea` join records. **No schema change**: there is no
`idea.tripID` (ADR-0007 / PRODUCT.md:56); association is a query over joins. **Free
ideas show no badge** (keep the junk drawer clean). An idea can be on several trips,
so the badge shows the **most-actionable** status: scheduled > upcoming > someday >
visited. Pays off most inside a capsule (trip-scoped) view — the "still free to pull
vs. already committed" signal, same data the not-yet-visited filter uses. Refs:
`TripIdea` join lifecycle, `IdeasScreen` / `PoolMapView`, ADR-0004 (map+filter is the
guide). **Mockup:** `docs/mockups/ideas-trip-awareness.html`.

## His/hers rating rendering redesign + "match" signal (from Jon, 2026-06-15) — DONE

Implemented 2026-06-15 on branch `m3e-ideas-trip-awareness`. The repeated-hearts
render is gone: `InterestView` now draws each planner's level as a **4-segment
filled bar** (Must Do 4 red / Want to Do 3 orange / Could Do 1 yellow), a red
minus for Do Not Do, a "?" for Decide Later, and an empty outline for *pending*
— so Decide Later reads distinct from not-yet-rated. The his/hers row appears
only once **someone** has rated (every party planner then shows, the unrated one
pending), keeping fully-unrated ideas quiet. **Match** (`Interest.standing` /
`isMatch`: ≥2 planners ≥ Want to Do; `passed` = ≥2 Do Not Do) surfaces as a
warm-pink `MatchPill` plus a "Matches only" filter and a "Matches first" sort
(both in the filter menu) that floats matches up and sinks mutual passes — the
worklist. The 5-level scale and rawValues are untouched (ADR-0007 intact). New
pure core in `Interest.swift` with `InterestMatchTests`. Original note below.

*Presentation-only — model is already settled, do NOT touch the scale.* The flames
rating is implemented (per-planner `IdeaInterest`, ADR-0007; 5-level scale Must Do /
Want to Do / Could Do / Do Not Do / Decide Later, recovered-requirements §2) but
renders **illegibly** as repeated hearts ("Jon ❤❤❤ Sam ❤") — you can't tell intensity
from count, and "Decide Later" / not-yet-rated isn't visually distinct from "unrated."
Fix the rendering: show each person's level as a **single legible indicator**, and make
**"Decide Later" distinct from "not yet rated"** (pending). **Keep the 5 levels** — the
scale is load-bearing for shortlist default-ordering and the start-day solver's
weighting (recovered-requirements §2; trip-time-model.md §3 "Must Do loud, Could Do
whisper"); collapsing to yes/no would re-open ADR-0007 and gut the solver.

Additive: surface **"match"** — both planners rated it highly (threshold, e.g. both
≥ Want to Do) — as a derived badge + a sort/filter ("show matches"), turning the pool
into a worklist (matches float up, passed sinks). Match is a **projection of the
flames**, not a separate vote — keeps ADR-0007 intact. Refs: `InterestView`,
`IdeaInterest`, ADR-0007.
