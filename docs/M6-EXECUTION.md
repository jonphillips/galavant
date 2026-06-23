# M6 (Intelligence) — execution briefs

Paste the relevant brief into a **fresh session** to execute one M6 slice. Each is
self-contained: it names the authoritative ADR, the in-tree precedent to clone, the
**skill checkpoints** for past-cutoff APIs (where recall fails — invoke the skill,
don't guess), where tests go, and the done-criteria. Open the session with the
slice's **suggested model** (ROADMAP M6).

Design lives in the ADRs (`docs/decisions/0014`–`0018`); these are the operational
wrappers, not a re-statement of the design.

---

## Shared guardrails (apply to every brief)

- **Read first:** `CLAUDE.md`, `docs/STYLE.md`, the slice's ADR, and
  `~/code/jon-platform/AGENTS.md`. Honor house style — structs by default, functional
  core + impossible-states enums, swift-dependencies, no singletons, 2-space indent,
  **no version suffixes anywhere** (ADR-0006).
- **Toolchain:** `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`
  before building. XcodeGen owns the project — edit `project.yml`, then
  `xcodegen generate`; **every package product a target imports must be declared in
  `project.yml` deps** or regenerate drops the link (Undefined symbols).
- **Tests live in the SPM package, never the app target** (the app target has no test
  bundle — `galavant-app-target-untestable`). Put logic in `GalavantSchema` /
  `GalavantPlaces` / `GalavantCapture` and test it there; the app target is the thin
  integration layer.
- **Persistence (CloudKit rules):** UUID primary keys; **one real FK** per synced
  record (ADR-0007), loose optional UUIDs for cross-refs (reconciled/orphan-dropped on
  read); additive migrations in `GalavantSchema/Database.swift` (excluded from the
  drift gate — it accretes forever); register new tables with the SyncEngine.
- **SQLiteData/StructuredQueries move fast** — invoke **`pfw-sqlite-data`** /
  **`pfw-structured-queries`** for `@Table`/`@FetchAll`/query syntax rather than
  recalling it; verify against current docs.
- **Verify before declaring done:**
  `swift test --package-path GalavantLibrary` → green;
  `xcodebuild build -project Galavant.xcodeproj -scheme Galavant -destination 'generic/platform=iOS Simulator'` → BUILD SUCCEEDED;
  `swiftlint lint --strict` → exit 0 (the pre-commit hook runs this; keep new types
  under the drift-gate thresholds — split into extensions/files if they grow fat).
- **Don't commit or open PRs unless asked.** Branch off `main` first if you do.

---

## M6a — model-access substrate · **Opus**

**Goal:** build the `ModelClient` boundary from ADR-0014 — the tiered seam every later
AI feature calls through. This is foundational; everything inherits it.

**ADR:** `docs/decisions/0014-ai-model-access.md` (read in full).

**Reuse / generalize:** the existing on-device `FoundationModels` plumbing —
`PlaceIntelligence` in `GalavantPlaces` (M4d) — becomes the on-device tier. Follow the
injectable-client pattern already in the package (`PlaceSearchClient`,
`directionsClient`, `PlaceIntelligence`) — `inject-io-boundaries-early`.

**Slices:**
1. **The protocol + value types** in a new SPM target (Galavant-scoped name, ADR-0006:
   it's app-internal): `ModelClient` (`complete` + `stream`), `ModelTier`,
   `ModelRequest`/`ModelResponse`/`ModelChunk`. Declare the target + its app dep in
   `project.yml`. Unit-test the request-assembly logic with a **stub backend** (no
   network, no device model) — the package-home pattern.
2. **`OnDeviceModelClient`** wrapping `FoundationModels` (lift from / share with
   `PlaceIntelligence`).
3. **`AnthropicModelClient`** — a thin `URLSession` client against
   `POST https://api.anthropic.com/v1/messages` (`x-api-key`,
   `anthropic-version: 2023-06-01`, SSE streaming). Default model **`claude-opus-4-8`**.
4. **Keychain key storage** + a minimal settings surface to enter/clear the key; absent
   a key → frontier disabled, on-device offered. (Settings can be a stub view this
   slice if the "You" area isn't built yet.)

**Skill checkpoints (past cutoff — invoke, don't guess):**
- **`claude-api`** before writing any Anthropic call — current `/v1/messages` shape,
  SSE streaming, tool-use loop, exact model IDs (the skill is authoritative;
  `claude-opus-4-8` is the default).
- **`swiftui-specialist`** / **`swiftui-whats-new-27`** for any iOS-27 SwiftUI/settings
  UI; **`pfw-dependencies`** for registering `@Dependency(\.modelClient)`.

**Done when:** a stub-backed unit test exercises `complete`/`stream` through the
protocol; `OnDeviceModelClient` answers a trivial prompt on an eligible device; with a
key in the Keychain, `AnthropicModelClient` streams a response from `claude-opus-4-8`;
no key → on-device path only. (Frontier verification is device + real key, not the
sim.)

---

## M6b — source evaluations + taste profile · **Sonnet** *(the Sonnet-solo slice)*

**Goal:** add the `IdeaEvaluation` and `TravelProfile` records from ADR-0015. Pure
schema/domain — **no model plumbing**, independent of M6a, so it can run in parallel.

**ADR:** `docs/decisions/0015-source-evaluations-and-taste-profile.md`.

**Clone this precedent (it's nearly line-for-line):** `TripStay` / ADR-0011. Read
`GalavantSchema/TripStay.swift`, `TripStayOperations.swift`, the `stays` projections in
`TripPlan.swift`, `Database.swift` (the TripStay migration + SyncEngine registration),
and `Tests/GalavantSchemaTests/TripStayTests.swift`. `IdeaEvaluation` is the same
shape: real FK → `TravelParty`, loose optional `ideaID`, orphan-drops on read,
born-not-pulled.

**Slices:**
1. **`IdeaEvaluation` `@Table`** (fields per ADR-0015 §1 — `sourceName`, `kind`
   `EvaluationKind`, `nativeValueText`/`Number`/`Max`, `nativeDisplay`, dates,
   `confidence`/`staleness` enums, `sourceURL`, `summary`) + the enums; migration +
   SyncEngine registration; create/edit/delete ops (mirror `TripStayOperations`);
   read-model `evaluations(forIdea:)` + a current-vs-historical helper reusing the
   orphan-drop reconciliation. Tests cloning `TripStayTests` (incl. orphan-drop + a
   multi-evaluation-per-idea case).
2. **`TravelProfile` `@Table`** (real FK → `TravelParty`, loose optional `plannerID` —
   nil = shared household, set = overlay; `preferences: String`) + migration +
   SyncEngine; upsert ops for the shared row and per-planner overlays; a read helper
   that assembles "shared + this planner's overlay." Tests.
3. **Detail-view display (app target):** show source-native ratings faithfully on the
   idea detail (`Michelin: ★★★`, `Andrew Harper: 96/100`, `Jon: Anchor`) with
   last-verified/confidence — **not** a normalized score. `TravelProfile` editing UI
   can be a simple form (settings/"You" area, or a stub entry point).

**Skill checkpoints:** **`pfw-sqlite-data`** / **`pfw-structured-queries`** for the
`@Table` + queries; **`pfw-testing`** for the suite; **`pfw-modern-swiftui`** for the
detail/edit views.

**Keep distinct from `IdeaInterest`** — evaluations are external judgments, a third
input; do **not** merge them into the his/hers `Interest.standing` match (ADR-0015 §2).

**Done when:** package tests green (new suites for both records, orphan-drop covered);
an idea with a Michelin `★★★` and a Harper `96/100` shows both natively on the detail;
a shared + per-planner profile round-trips through the DB.

---

## M6c — source-aware capture + on-demand field supplement · **Opus**

**Goal:** recognize ratings sources on capture → write `IdeaEvaluation`; add a per-field
"supplement" affordance (hours first) on a cheapest-source ladder. ADR-0016.

**ADR:** `docs/decisions/0016-source-aware-capture-and-field-supplement.md`. Depends on
M6b (the `IdeaEvaluation` record) and the M4 capture stack.

**Reuse:** `GalavantCapture` (`ParsedPage`, the value-voting parser — it already
extracts `openingHours`); `GalavantPlaces` (`CapturedPlace.from(ParsedPage:)`,
`PlaceMatcher`); M4g's `PageFetcher` / `PageParser` / `PlaceEnricher`. Honor the
**portfolio-extraction seam** — the parser stays domain-free (never sees `Idea`/
`IdeaEvaluation`).

**Slices:**
1. **`ParsedEvaluation` on `ParsedPage`** (domain-free, in `GalavantCapture`) +
   recognizers as pure functions, value-voted least→most structured: schema.org
   `aggregateRating`/`Rating` first, then per-host (Michelin/Harper/Forbes/50 Best),
   LLM **extract-only** fallback (via `ModelClient`, on-device tier; "preserve native,
   never invent, null if missing"). Fixture tests (a Michelin JSON-LD page, a Harper
   page, a no-structured-data page).
2. **Bridge mapping** `ParsedEvaluation → IdeaEvaluation.Draft` in `GalavantPlaces`,
   stamping `confidence`/`staleness`/`recordedAt`/`ideaID`/`travelPartyID`; write idea
   + evaluations in **one transaction**; surface detected evaluations in the capture
   confirm sheet (`GalavantShare`).
3. **`FieldSupplement` ladder** (each an injectable client): MapKit hours probe →
   official-site fetch (reuse `PageFetcher`) → HITL `WKWebView`. **Hours land on `Idea`**
   (facts), not `IdeaEvaluation` (judgments) — the load-bearing split. A "supplement
   hours" affordance on the idea detail, write-back with provenance.

**Skill checkpoints (critical — past cutoff):**
- **Grep the Xcode-beta SDK headers** to confirm whether `MKMapItem` exposes opening
  hours on iOS 27 (`apple-sdk-headers-authoritative` — there is **no** MapKit Xcode
  skill; the headers are authoritative). That answer decides whether rung 1 exists.
- **`claude-api`** if the LLM extract-fallback uses the frontier tier;
  **`swiftui-whats-new-27`** for `WKWebView`/SwiftUI integration.

**Do not** scrape Google SERPs (ToS/brittle).

**Done when:** sharing a Michelin page lands the idea **and** a faithful `★★★`
evaluation; a tap on an hours-less idea fills hours from the cheapest available rung,
stamped with provenance; parser recognizer tests green.

---

## M6d — context-aware chat window · **Opus**

**Goal:** a chat panel that discusses the current screen, backed by the tiered
`ModelClient`, with the pool verbs as tools. ADR-0017. Lands last — depends on M6a
(the boundary + frontier streaming) and reads M6b's evaluations/profile as context.

**ADR:** `docs/decisions/0017-context-aware-chat-window.md`.

**Slices:**
1. **`ChatContext`** (enum: `.idea(...)` / `.trip(TripPlan)` / `.pool(...)`) built by
   the presenting screen from existing read-models; serialized into the prompt. The
   **taste profile** (M6b) is injected by the `ModelClient` boundary, not re-plumbed
   here.
2. **`ChatModel`** (`@Observable`, in the package) driving `ModelClient.stream`, holding
   context + tier choice + an **ephemeral** (unsynced) message list. Unit-test
   tool-dispatch + context-serialization with a stub `ModelClient`.
3. **Tools over `GalavantSchema`** — v1 read-leaning: `queryPool` (NL filter over ideas)
   + `createIdea` (lands a **candidate**, ADR-0013). Defer `scheduleStop` (read +
   propose; don't mutate the trip — ADR-0004). Share the verb definitions with the
   App Intents work (the "AI pool-stocking" BACKLOG entry).
4. **The panel UI:** iPhone sheet / iPad **side column** (reuse the canvas
   `horizontalSizeClass` split — **not** a nested `NavigationStack` in the iPad detail,
   `ipad-nested-navigationstack-trap`); a clear tier indicator + an explicit "data
   leaves the device" affordance on the frontier path; on-device is the default.

**Skill checkpoints (past cutoff):**
- **`claude-api`** for the streaming + **tool-use loop** shape (model emits `tool_use`
  → app runs the verb → returns `tool_result` → continue) and model IDs
  (`claude-opus-4-8` for the chat's reasoning).
- **`swiftui-specialist`** / **`swiftui-whats-new-27`** for the streaming chat UI;
  **`pfw-observable-models`** for `ChatModel`.

**Done when:** from an idea/trip screen, a chat opens carrying that screen's context;
on-device answers a context question privately; with a key, the frontier tier answers
"which Denmark food ideas haven't we visited?" via a `queryPool` tool call; `createIdea`
from chat lands a candidate pin; the frontier path visibly flags that data leaves the
device.

---

## M6e — AI pool-stocking, the discovery pipeline · **Opus** *(spike-gated)*

**Goal:** query + region → candidate pool ideas, grounded in live web search, deduped
against the pool. **AI stocks the pool; it never pulls onto a trip.** ADR-0018.
Frontier-only (on-device can't web-search), BYO-key (ADR-0014); a candidate is a pool
`Idea` on no trip (ADR-0013 — **no new table** for v1).

**ADR:** `docs/decisions/0018-ai-pool-stocking-discovery.md` (read in full). Depends on
M6a (the `ModelClient`/`AnthropicWire` boundary) and the M4 place stack.

**Reuse:** `GalavantAI` (`ModelClient.complete`, `AnthropicWire.requestData`/`.response`);
`GalavantPlaces` `PlaceMatcher.match` (M4b/c MapKit resolve ladder), `PlaceMatching.score`
(overlap), `PlaceEnricher` (M4g); `MapRegion.contains(latitude:longitude:)`; `Idea.Draft`
+ save.

**Architecture (ADR-0018):** one `ModelClient.complete()` frontier call with web search
on → a strict **JSON candidate array** (`name`/`kind`/`locality`/`region`/`note`/`sourceURL`);
the **app parses + owns dedup/persistence** — the model finds & structures, never writes.
(Simpler/more testable than a client-side tool-loop for a batch; the `findPlaces`
App-Intent wrapper comes later.) Resolve each via `PlaceMatcher` → dedup against the pool
(`PlaceMatching.score` + coordinate proximity) → `MapRegion` auto-bucket → `Idea.Draft`
save as a **candidate** → optional `PlaceEnricher`.

**Wire change first (`GalavantAI`) — `claude-api` skill before writing:**
- `ModelRequest`: add `webSearchMaxUses: Int?`.
- `AnthropicWire.requestData`: emit `{"type":"web_search_20250305","name":"web_search","max_uses":N}`.
- `AnthropicWire.response`: tolerate `server_tool_use` / `web_search_tool_result` blocks
  (server-executed — ignore) and still capture final text. **Non-streaming `complete()`
  only.** Unit-test request-assembly + response-parse against the stub backend.

**Slices:**
0. **The spike (build now, Jon runs it):** the `web_search` wire change + a
   `PlaceDiscoveryClient` (grounded `complete()` + JSON parse). A **dev-only entry on the
   Ideas-screen toolbar** (Jon's call — small, easy to delete; *not* a separate debug
   view) that dumps the raw candidate list (names/localities/sourceURLs) — no dedup, no
   save. Tests: request-assembly + JSON parse vs. stub. Jon runs the live call on-device
   for "all 2–3★ Michelin in the Loire". **Decision gate** — eyeball
   completeness/accuracy/freshness; good → build on, weak → tune prompt/search first.
1. **Dedup core (pure, tested):** `DiscoveryDedup` (`.new`/`.duplicate(Idea.ID)`/
   `.nearMatch(Idea.ID)`) + `MapRegion` bucketing; fixture tests (exact dup, near-match,
   distinct, junk).
2. **Resolution + persistence:** `PlaceMatcher` resolve → dedup → batch `Idea.save` →
   optional enrich; tested with an in-memory DB + fixture matcher.
3. **The real UI:** region-scoped discovery entry + candidate review (list + candidate-
   tinted pins on `PoolMapView`, reuse ADR-0013 styling) + Add all/selected.
   `swiftui-specialist` checkpoint.
4. **Docs:** flip ADR-0018 to accepted; ROADMAP/BACKLOG updates.

**Skill checkpoints (past cutoff):** **`claude-api`** for the `web_search` server-tool
block + response shape + model IDs (`claude-opus-4-8`) before any wire change;
**`swiftui-specialist`** for the discovery/review UI.

**Targets/tests/verify:** code lands in existing targets (`GalavantAI` + `GalavantPlaces`
+ app); the orchestrator goes in `GalavantPlaces` (add a `GalavantAI` dep in `project.yml`
if missing → `xcodegen generate`; **no new SPM target expected**). Tests in the package.
`swift test` green · app `xcodebuild` succeeds · `swiftlint --strict` clean.

**Done when:** the spike returns a usable candidate set for the Loire-Michelin query
on-device with Jon's key; dedup classifies new/dup/near-match correctly; discovered
places land as candidate pins auto-bucketed by region; no candidate is ever auto-pulled
onto a trip.
