# Galavant Roadmap

Vertical slices; each milestone ends with something that runs. Riskiest unknowns
first. Update this file when reality diverges — it's a living doc, not a contract.

Each unbuilt slice carries a **suggested executor model** — conservative and
Opus-leaning. Sonnet only where the work is well-precedented and low-novelty (an
existing in-tree pattern to clone, guarded by tests + the drift gate); Opus wherever
quality matters more (foundational boundaries, judgment-heavy design) or the surface
is API-novel/past-cutoff (new OS-27 / FoundationModels / App Intents / frontier-API
work, where recall fails and current docs must be checked). The tag tells you when
opening a fresh Opus session is worth it.

## M0 — Skeleton that persists ✅ (done 2026-06-10, Xcode 27 beta 1)
- Xcode project: multiplatform SwiftUI app + share-extension target stub + local SPM package
- SQLiteData wired up; database in the **app group container** from day one
- Minimal `Idea` model (name, coordinate, region, notes) with CloudKit-legal schema (UUID PKs)
- List + add/edit form proving @FetchAll observation and swift-navigation Destination pattern
- ✅ Done when: add an idea on iPhone sim, relaunch, it's still there

## M1 — The CloudKit bet ✅ (2026-06-12, architecture proven)
- ✅ SQLiteData CloudKit sync live (SyncEngine over travelParties+ideas; container iCloud.com.jonphillips.galavant)
- ✅ Two-device sync on one account — both directions, ~10s latency (sim 17 Pro ↔ 17 Pro Max)
- ✅ Travel-party share CREATED over the full graph (TravelParty root + ideas); valid share URL
- ⏳ Accept handshake deferred to real-device test at M5/TestFlight (simulator can't route it; ADR-0003)

## M2 — The pool *(in progress)*
- ✅ M2a: TravelParty/Planner/IdeaInterest schema, kinds, per-planner first-run identity, his/hers interest UI
- ✅ M2b: MapKit location search in the form (idea gets coordinates) + pool map with pins + list/map toggle
- ✅ M2c: first-class MapRegion (containment-based), pool filter (region/kind/visited), filter UI + define-region-from-map, filter-summary bar
- ✅ Capture polish: **search-first form** — place search leads, auto-populates name/kind/link/address/phone from MapKit (`MKMapItem` + pure `IdeaKind` POI mapping); ⏳ Tags (first-class?); ✅ location-search robustness (worldwide `MKLocalSearch` natural-language query — DONE 2026-06-16, docs/BACKLOG.md)
- ⏳ Second-device identity hardening (ADR-0008): bind-or-create planner picker, stray-party cleanup, IdeaInterest dedup-on-read
- Full Idea model: kinds, visited state, tags, URLs, images, opening days/hours and reservable-from (manual entry)
  - **Image storage strategy** (cross-cutting; inherited by M4 scraped images + M5
    Unsplash headers) — now settled in **ADR-0009**: CloudKit-native (no S3),
    pure processing split from stack-specific storage, a dedicated image table,
    resize-on-import display tier (~1600px/≈300 KB inline BLOB) with `CKAsset`
    full-res deferred. See the ADR before building.
- Planner identity (ADR-0007): Planner table, device-local currentPlannerID, first-run name capture
- **Per-planner flames ratings + notes** via single-FK Rating record (Must Do…Decide Later, his-and-hers; ADR-0007)
- MapRegions (port V2's working implementation) + region/tag/category/distance filtering
- Capture via MapKit search + manual entry
- Pool map view (PowerMap descendant)
- ✅ Done when: the Denmark junk drawer works — collect, filter, browse on a map

## M2→M3 — Adaptive nav shell ✅ (2026-06-12)
- ✅ AppContainer: tabs on iPhone, sidebar+detail split on iPad/Mac (prefersTabNavigation, ported from V2). AppScreen sections: Ideas (real) + Trips (placeholder). Fixes the "stretched iPhone" iPad layout.

## M3 — Trips ✅ (done 2026-06-20 — M3a–M3d + travel-time connectors, transport modes, "now" marker)
- ✅ M3a: Trip schema (certainty pipeline someday(rank)→targeted(year,quarter)→dated + lengthInDays, flat columns behind a `Certainty` enum facade) + TripIdea join with `considering→shortlisted→scheduled→done/skipped` status (ADR-0004); functional core (`Trip.create`/`update`/`reorderSomeday`/`sectioned`, `TripIdea.pull`/`setStatus`/`remove`) + 13 tests; Trips list grouped by certainty with create/edit form and reorderable() someday backlog (deployment target bumped to iOS 27 for native reorder). Demo trips seeded.
- ✅ M3b: pull-to-shortlist. Tapping a trip pushes a **Trip Planning screen** (segmented Shortlist | Add); Add shows the pool scoped by the reused M2c filters (region/kind/tag/visited) with pull → considering / straight-to-shortlist; Shortlist shows ranked pulls (reorderable()) + a Considering pile; per-row status menu (considering/shortlisted/scheduled/skipped/remove). Core: `TripIdea.reorderShortlist` + rank-on-promote in `setStatus` + pure `shortlist()`/`considering()`; 3 new tests (29 total). Edit moved into the planning screen. Title fix: trip name now shows (segmented control moved to a bar under the nav bar).
- ✅ M3c (2026-06-13): **the itinerary core** — day-relative scheduling. New
  `Schedule` facade (`unscheduled / day / daypart(DayPart) / timed`, dates never
  stored — derived from start; drops V2's `.exact`) over four flat columns on
  `TripIdea` behind the `Certainty`-style apply/rebuild contract; `DayPart` enum
  (Int-raw, `sortHour`). Functional core: `TripIdea.itinerary(_:lengthInDays:)`
  → `[ItineraryDay]` (every day present, intra-day sorted by `intraDaySort` then
  `shortlistRank`, out-of-range days clamp onto the last); `Trip.date(forDay:)`
  derives the calendar date for dated trips. DB ops `schedule`/`unschedule`/
  `markDone` (Done flips `Idea.visited` — post-trip feedback-to-pool, ADR-0004).
  UI: third **Itinerary** segment in the planning screen — day sections (header
  shows day # + weekday/date when dated) plus a **To Be Scheduled** bucket at the
  top for stops committed to the trip but not yet placed on a day (`.scheduled`
  with `dayNumber == nil`); an **Add Stop** sheet (pick idea + day or
  to-be-scheduled + time-of-day), per-stop menu to set/move day / set
  time-of-day / Skip / back-to-shortlist, and a swipe-to-Schedule on shortlist
  rows. Ideas page is **Ideas | Itinerary** with shortlist/scheduled/considering
  sections, one-tap state icons, and swipe Remove/Unschedule. 11 new tests (43 total). **Done is intentionally not a
  per-stop action** (Jon: completion is assumed once the trip passes) — the
  `markDone`→`visited` op stays as the mechanism for a future trip-level rollup +
  a "now" marker (docs/BACKLOG.md). Deferred: clock-time *entry* UI, drag stops
  between days, per-day region stops (`.timed` + schema already support the first;
  freeform stops shipped M3g, accommodations M3h, the now marker M3f). `TripRegion` join (single-FK→Trip ON DELETE CASCADE, loose regionID per ADR-0007) with `setRegions` reconcile + `regionIDs(forTrip:)`. `poolFiltered` now takes a region **union** (`regions: [MapRegion]`, empty = no constraint, match any); IdeasListModel + tests updated. Multi-region picker in the trip form; the Add lens (`Set<MapRegion.ID>`) **pre-seeds from the trip's regions** on appear. Demo trips pre-associated with regions. 32 tests green. (Reorder-on-fast-nav race parked as a beta-watch item — docs/KNOWN-ISSUES.md.)
- ✅ M3d (done, 2026-06-14): **map-as-canvas trip view** — the map is the
  trip's home (docs/trip-canvas.md). Full-bleed `TripCanvasMapView` with numbered,
  day-coloured sequence pins + per-day `MapPolyline`; a `DayChipBar` lens (All +
  Day 1…N) framing the camera via the pure `MapFraming` core (no MapKit, tested);
  the **Itinerary | Ideas** list surface (`TripDetailContent`) is the second
  projection of one shared selection (`canvasSelectedStopID`), with a pinned
  switcher and pin-tap→list autoscroll. **Platform split:** iPhone gets a
  persistent Apple-Maps-style bottom sheet; iPad gets a solid right-hand column
  beside the map (`horizontalSizeClass`) so map + itinerary are usable at once.
  Edit sits in the trip nav toolbar. Model `Mode`→`SheetTab` + canvas
  selection/lens state; `StopMenu` extracted; `TripItineraryView` gains
  `focusedDay` + selectable rows. 49 GalavantSchema tests green; builds clean.
  **Travel-time connectors deferred** (landed in M3f). (Metal API Validation
  off in the Run scheme — MapKit trips a false assert on the iOS 27 sim beta;
  docs/KNOWN-ISSUES.md.)
- ✅ M3e (2026-06-16, PRs #1–#2): **planning polish batch.** Ideas list
  **trip-awareness** — active-trip capsules (the certainty-derived launchpad: every
  dated/targeted trip + the top someday) and per-cell badges showing where an idea
  sits on the in-play trips. **His/hers rating redesign** + a pool match signal.
  Itinerary **cleanup**: one time vocabulary across rows (clock range = hard
  constraint, daypart = soft, bare day = faint affordance) and a category subtitle
  inside a single-destination trip. Refactor: the **`TripPlan` read-model** pulled
  out of `TripPlanningModel` into the tested functional core (the join + projections
  the views consume).
- ✅ M3f (2026-06-20): **travel-time connectors + now marker** (closes M3d's
  deferred connectors; docs/trip-canvas.md). Injectable `directionsClient`
  (MKDirections) fetches **walking ETAs** between consecutive located stops, cached
  by `LegKey`+mode; **transport-mode auto-detect** (walking ≥ 20 min → transit) with
  a **per-leg override**, and an **open-in-Maps** handoff per leg. `TravelConnector`
  rows interleave between stops; a **"Now" marker** divider marks the current moment
  in today's section on active **dated** trips (never undated). Pure `itineraryItems`
  weaves stops + connectors + marker. (Itinerary drag-between-days stays backed out —
  List DnD times out on Xcode 27 beta; docs/KNOWN-ISSUES.md.)
- ✅ M3g (2026-06-20, ADR-0010): **freeform itinerary stops** — a custom stop with
  no pool idea ("lunch", "train to Aarhus"), folded into the one `TripIdea` record
  (it *is* a point stop). Three slices: schema + read-model (`StopContent` enum
  `.idea`/`.freeform`, resolved totally — orphans/malformed dropped); re-key the stop
  ops to `TripIdea.ID` so they serve idea-backed and freeform alike; write path —
  per-section "+" drops a shortlisted idea straight onto a day, plus an **Add Custom
  Stop** sheet.
- ✅ M3h (2026-06-21, ADR-0011): **accommodations as stays** — a sibling
  trip-scoped `TripStay` record (a span, not a `Schedule` point). Three slices:
  schema + read-model (`TripStay` @Table, `stays` / `stays(coveringDay:)` / overlap
  flag / `baseStays` projections reusing `StopContent`); itinerary —
  `ItineraryItem.checkIn`/`.checkOut` rows woven by time (default evening / morning),
  a home-base chip on every covered day, write ops + "Stay here" / "Add Lodging"
  entry points, a lodging sheet whose hotel picker ties a stay to a pool `Idea` (so
  it gets a map pin) or a custom name; canvas — an off-sequence base pin on every
  covered day-lens + All, folded into camera framing, `locatedStops`/`legs`
  untouched. Deferred (clean seams): booking metadata / `pinnedDate`,
  per-day-region driving, stays summary band + spanning banner, hotel-anchored
  routing. **Next: numbered itinerary rows (located-only, matching map pins), then
  per-day regions.**
- Trip model: **certainty lifecycle** someday(rank) → targeted(year, quarter) → dated (docs/trip-time-model.md); duration in days; **day-number-relative itinerary** + **TripIdea join with status lifecycle** (ADR-0004)
- Trips list grouped by certainty; drag-rank the someday backlog; trip link bookmarks (label+URL)
- Planning view: pool filtered by trip lens → pull to shortlist
- Shortlist drag-to-rank ordering
- Itinerary: days, per-day regions (with percentDay splits), stops with the V2 Schedule enum; "bookable now / opens in N days" section on dated trips
- Post-trip: done/skipped feedback to pool
- Map-as-canvas trip view: day chips, numbered sequence pins, bottom-sheet timeline (docs/trip-canvas.md)
- ✅ Travel-time connectors between a day's stops (MKDirections ETAs + transport-mode auto-detect/per-leg override; `TravelConnector`/`DirectionsClient`, 2026-06-20) + open-in-Maps handoff (M3d). The "now" you-are-here marker on active dated trips also shipped (2026-06-20; docs/BACKLOG.md "now marker" item).
- Stretch: start-day solver (slide start date → check key stops' open days; docs/trip-time-model.md)
- ✅ Done when: the Copenhagen scenario works end to end

## M4 — Capture from anywhere ✅ (done 2026-06-18 — M4a–M4h; CloudKit BLOB sync still to verify on two real devices, ADR-0009 §4)
- ✅ M4a (2026-06-16): **the pure parser engine** — new isolated SPM target
  `GalavantCapture` (SwiftSoup + Foundation only; **no** SwiftUI/CloudKit, never
  sees `Idea`/`Trip` — the portfolio-extraction seam, BACKLOG/ADR-0009). `HTML →
  ParsedPage` (a domain-free value type: title/summary/phone/email/`websiteURL`/
  coordinate/address/images/socials/`schemaTypes`/`openingHours`/`capturedAt`).
  Layers run least→most structured into one **value vote** (V1's
  `consolidate_scored_attrs`): **JSON-LD first** (scraping-enrichment.md precedent),
  then OpenGraph/Twitter meta (incl. the underused `place:location:*` +
  `business:contact_data:*`), then HTML microdata; ties break to earliest-seen so
  authoritative passes win. Images/socials/hours accumulate ordered-unique; image
  hygiene filter + relative-URL resolution ported from V1. `websiteURL` (vs
  `sourceURL`) is surfaced as the **two-hop** trigger (orchestration deferred to
  M4b/c; `URLSession` second-hop fetch is feasible on-device — no sandbox block,
  only ATS). Pure/best-effort (never throws); `capturedAt` injected. 9 fixture
  tests (no network/UI). Engine is package-only — not linked into the app yet.
- ✅ M4b (2026-06-16): **the domain bridge + Apple Maps matching policy** (pure,
  no network — execution wires in M4c). (1) `IdeaKind(schemaOrgType:)` +
  `(schemaOrgTypes:)` — schema.org `@type` → kind, the on-device cousin of the POI
  mapping; generic types (`Thing`/`Organization`/`LocalBusiness`/`Place`) stay nil,
  most-specific wins. (2) `CapturedPlace.from(_:id:travelPartyID:)` in
  `GalavantPlaces` — maps `ParsedPage` → an `Idea.Draft` (confirm-and-tweak, like
  search-first capture) **and carries the signals the `Idea` schema doesn't yet
  hold** (images, socials, opening hours, the two-hop `websiteURL`) so M4c/M4d
  don't re-parse; `id` passed in for `@Dependency(\.uuid)` control. (3)
  `PlaceMatching` — ports V1's `PlaceSearchStrategy` as pure string functions:
  the **signal ladder** (`coordinates → geocodeAddress → biasedTextSearch →
  worldwideTextSearch`, bias is a hint + auto-widen on low score) and
  common-substring **scoring** (name + street overlap). `GalavantPlaces` now
  depends on `GalavantCapture`. 22 new tests across the two test targets; full
  package suite green. Still package-only — not linked into the app.
- ✅ M4c (2026-06-16): **the share extension — the first runnable capture slice.**
  Share a web page → a confirm-and-tweak sheet → it's in the pool. (a) The
  *testable* core in `GalavantPlaces`: `PlaceMatcher` executes the M4b ladder
  against injected geocode/search (iOS 26 `MKGeocodingRequest`; `CLGeocoder`
  deprecated) with auto-widen; `CaptureModel` (`@Observable`) does
  parse→match→editable draft→save under the default party, tested with an
  in-memory DB + fixture matcher. (b) The extension shell (`GalavantShare`,
  hand-verified — not unit-testable): `ExtensionPreProcessing.js` hands over
  Safari's **rendered DOM** (WebPage activation + JS preprocessing; WebURL +
  `URLSession` Safari-UA fetch as fallback); `ShareViewController` bootstraps the
  app-group DB **local-only** (`startSyncEngine: false` — the app owns sync) and
  hosts `CaptureConfirmView` (a focused form, not the app-target `IdeaFormView`).
  **Single-hop by Jon's call** — the place's `websiteURL` is saved for the app's
  deferred second-hop enrichment (M4d). Fixed a latent `project.yml` drift en
  route: the app used `GalavantPlaces` but never declared it (committed `.pbxproj`
  carried the link; `xcodegen generate` would drop it) — now declared. App +
  extension build clean. **Verify on device/sim:** share a restaurant page from
  Safari → confirm → it lands in the pool.
- ✅ M4d (2026-06-17): **on-device Apple Intelligence enrichment** — `PlaceIntelligence`,
  an injectable `FoundationModels` client in `GalavantPlaces` (the cousin of
  `PlaceMatcher`), refines the parse in `CaptureModel.prepare()` **before** the
  Apple Maps match. One guided-generation call (`@Generable` + `@Guide(.anyOf(…))`
  for the kind) returns a `PlaceRefinement` (clean name / mined city+region / clean
  notes / classified kind); a **pure** `ParsedPage.applying(_:)` merges it
  confirm-and-tweak (cleans a *chrome* title only; fills locality/region/summary
  only when blank), and kind fills the draft only when structured data left it
  blank. A mined city feeds the match query, so a name-only page (koancph.dk's
  "Koan") resolves — the deferred M4d fix. **Availability-gated**
  (`SystemLanguageModel.default.availability`) → silent fallback to the
  deterministic parser when Apple Intelligence is off/unsupported; `testValue` is a
  no-op so the parser path stays the tested default. FoundationModels lives only
  behind the client closure; the merge + orchestration are unit-tested with a
  fixture (incl. the Koan→Copenhagen end-to-end proof). 9 new tests; full package
  suite + app/extension build green. **Verify on an eligible device** (Apple
  Intelligence isn't on the simulator): share koancph.dk → confirm shows clean
  "Koan", Copenhagen, a sensible kind, and a resolved location.
  - **Notes follow-up**: `PageParser` now also extracts a cleaned, bounded
    body-text excerpt (boilerplate stripped) onto `ParsedPage`, fed to the model so
    it can write notes even when the page has no `og:description` (Alouette). Notes
    are treated as a *generated* field — the model's neutral, de-marketed
    description **supersedes** the raw page description (which is usually marketing
    copy, e.g. Forestis); falls back to the page's own summary when the model is
    silent/unavailable. Instructions/`@Guide` forbid taglines, questions, and calls
    to action.
- ✅ M4e (2026-06-17): **image foundation** (ADR-0009), package-only. New pure
  `GalavantImaging` target — `ImageProcessing.process(Data)` → display
  (~1600 px / ≈300 KB, quality step-down) + thumbnail, ImageIO/CoreGraphics only
  (no UI/CloudKit/persistence — the portfolio-extraction candidate); never
  upscales, bakes in EXIF orientation. `ImageAsset` table in `GalavantSchema`:
  single real FK to `Idea` (ON DELETE CASCADE, ADR-0007), inline display/thumbnail
  BLOBs, `sourceURL`, `sortRank`, `isHeader`; idempotent `store()` on
  `(ideaID, sourceURL)`, exclusive `setHeader`, header-first `images(forIdea:)`.
  Migration + SyncEngine registration. 9 tests. Idea-scoped for M4 (M5 trip
  headers need their own table — single-FK rule).
- ✅ M4f (2026-06-17): **capture stores a header image** — closes the gate's "with
  image" half. Hybrid placement: the share extension fetches + shrinks just the
  single best candidate (`imageURLs.first`; one image stays inside the ~120 MB
  budget) and stores it as the idea's header, in the same write; the full ranked
  gallery is the app's job. New injectable `ImageFetcher` (Safari-UA, 12 MB cap,
  best-effort — a missing image never blocks the save). Pool cells show a header
  thumbnail (a light `@Selection` of header thumbnails only — no display BLOBs in
  the list), falling back to the kind glyph. 2 tests.
- ✅ M4g (2026-06-17): **two-hop enrichment + Vision-ranked images** (app-side).
  Once an idea is in the pool, the app re-fetches its own website (the preserved
  `url` — richer than the often-aggregator shared page), re-parses, backfills blank
  facts via Apple Intelligence (notes/region/phone/address/kind), and downloads +
  Vision-ranks its images. New injectable `PageFetcher` + `ImageRecommender` (wraps
  Vision `CalculateImageAestheticsScoresRequest` — `overallScore` + `isUtility`
  demotes logos/screenshots; `testValue` flat-scores so the parser order is the
  fallback). `PlaceEnricher` orchestrates fetch→parse→backfill→fetch+score+process
  up to 6 images→store idempotently, top-ranked becomes the header. Gated on a new
  synced `Idea.enrichedAt` (runs once; a second device skips). Trigger is
  state-derived: `enrichPendingIdeas()` sweeps un-enriched ideas with a URL,
  bounded, on appear / DatabaseChange / foreground; in-process writes flow back via
  `@FetchAll` so headers/notes update live. 4 tests.
- ✅ M4h (2026-06-17): **the image gallery / cover picker** (Jon's V1 "show all
  images, let me pick"). The idea form gains a Photos section — a large cover
  preview over a tappable thumbnail strip; the enrichment's Vision-recommended
  cover is the default, tapping a thumbnail overrides it (safe — enrichment won't
  re-run). `IdeaFormModel` loads the idea's `ImageAsset`s and writes `setHeader`.
- Share extension: URL in → scraped page (SwiftSoup, port V1) → idea form → saved to shared DB
- Enrichment pipeline per `docs/scraping-enrichment.md` (port of the V1 server's
  metatag/OpenGraph/schema.org layering, value voting, and MKLocalSearch matching; add JSON-LD and openingHours capture)
- ⏳ In-app browser capture flow (port V2's WebSearch) — deferred; the share
  extension covers the daily capture flow.
- ✅ Done when: share a restaurant page from Safari, it's in the pool with image and
  location, and it syncs. *(Local storage + display done & tested; CloudKit BLOB
  sync still to be verified on two real devices — ADR-0009 §4.)*

## M5 — Polish & distribution
- iPad/Mac split-view layouts properly done
- Weather chips on itinerary days: climate normals when far out/undated, WeatherKit forecast inside 10 days (docs/trip-canvas.md)
- Unsplash header images (port GalavantLibrary's UnsplashSearch) if still wanted
- Sync health surface: show whether CloudKit sync is active or local-only (silent degradation is fine for dev, not for two-person use)
- TestFlight setup; app on wife's phone
- Future/backlog: booking-window local notifications with time-of-day precision (the 3 a.m. hard-to-get-restaurant alarm — docs/recovered-requirements.md Q2)
- ✅ Done when: both phones run it daily

## M6 — Intelligence *(designing)*

The AI layer, from the 2026-06-22 design chat. Spine: **AI captures, enriches, and
explains the pool — native-faithful and provenance-aware; it never silently becomes
the authority and never makes the pull/route decision** (reinforces ADR-0004's
explicit-pull boundary). Stays no-server (ADR-0001): on-device models + the user's
own frontier key + on-device web fetch, never infra Jon runs. Slices are sequenced
so each earns the next — substrate → knowledge model → enrichment → conversation.
Per-slice hand-off prompts (precedents to clone, skill checkpoints, done-criteria)
live in `docs/M6-EXECUTION.md` — paste one into a fresh session of the suggested
model.

- ✅ **M6a — model-access substrate (ADR-0014, accepted 2026-06-22):** one
  injectable `ModelClient` boundary, two tiers — on-device `FoundationModels`
  (generalizing M4d's `PlaceIntelligence`) + frontier Anthropic/OpenAI authenticated
  with the user's own Keychain API key. Establishes that BYO-key frontier APIs
  preserve no-server (no infra/auth/shared-secret) and that the key is a device-local
  exception to ADR-0003. Design only; client + Keychain UI build with the first
  consumer below. **Suggested executor: Opus** — the frontier URLSession/SSE client,
  Keychain storage, and tool-use loop are past-cutoff and foundational; everything
  downstream inherits this boundary, so accuracy here is worth the spend.
- ⏳ **M6b — source evaluations + taste profile (ADR-0015):** an `IdeaEvaluation`
  sibling record (the `TripStay`/ADR-0011 pattern — loose optional `ideaID`,
  native-faithful source/kind/value/display, provenance + staleness; collapse
  source+rating-system to enums for v1; defer the normalized band) so Michelin /
  Andrew Harper / etc. ratings attach to an `Idea` faithfully. Plus a `TravelProfile`
  (shared party + per-planner overlay) injected through the `ModelClient` boundary as
  the reusable taste prompt. Pure schema/domain — independent of the model plumbing.
  **Suggested executor: Sonnet** — a `TripStay`/ADR-0011 clone with a built, tested
  precedent in-tree; low novelty, guarded by the package test suite + drift gate. The
  one clear Sonnet-solo slice in M6.
- ⏳ **M6c — source-aware capture + on-demand supplement (ADR-0016):** sharing from a
  ratings source recognizes it and routes the rating into `IdeaEvaluation`; a
  per-field "supplement" affordance fills gaps (opening hours first) via the
  cheapest-source ladder — MapKit (`MKMapItem`) → the place's official site → a
  human-in-the-loop `WKWebView` scrape. Generalizes M4g's `PlaceEnricher`,
  interactive and field-targeted. (Not Google SERP scraping — ToS/brittle.)
  **Suggested executor: Opus** — `MKMapItem` hours (iOS 27, past cutoff), the HITL
  `WKWebView` flow, and the source recognizers / LLM extract-fallback are API-novel
  and judgment-heavy; wants the Apple-SDK + claude-api skills at the rungs.
- ⏳ **M6d — context-aware chat window (ADR-0017):** discuss the current screen
  (this idea + its evaluations + his/hers ratings; or this trip's itinerary) with the
  tiered backend — on-device by default, BYO-key frontier opt-in per conversation.
  Tools = the App Intents pool verbs (`findPlaces` / `createIdea` / query-the-pool)
  so "which Denmark food ideas haven't we visited?" is a tool call, not a
  hallucination. Privacy posture is a surfaced choice, never silent.
  **Suggested executor: Opus** — the frontier SSE + tool-use loop, streaming chat UI,
  and App Intents tool definitions are the most API-novel and most visible surface in
  M6; first real consumer of the frontier tier.
- Adjacent long-term bet (own slice when it ripens): **match *prediction*** — extend
  the his/hers `Interest.standing` projection from a lagging tally to a *predicted*
  match for unrated ideas, seeded by the taste profile. The most differentiated
  feature, unique to a two-person app. **Suggested executor: Opus** (when it ripens) —
  modeling judgment + the taste signal.
- ✅ Done when: shared Michelin/Harper pages land faithful ratings on pool ideas, a
  tap supplements a stop's opening hours, and the chat window answers a real
  pool/trip question on-device or with Jon's key.
