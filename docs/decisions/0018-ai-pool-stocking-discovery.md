# ADR-0018: AI pool-stocking — the discovery pipeline

*Status: proposed — 2026-06-23 (the slice-0 spike gates final acceptance; see
Consequences)*

## Context

The concrete first slice of the long-standing "AI assistant" theme
(`docs/BACKLOG.md` — "AI pool-stocking via App Intents", 2026-06-22), and the
successor to the M6 enrichment/chat work now merged (M6a–d). Where M6c *enriches*
an already-known place, this slice *discovers* new ones: **query + region → a set
of candidate pool ideas, grounded in live web search, deduped against the pool.**

Jon's canonical example: *"find me all the 2- and 3-star Michelin restaurants in
the Loire and create ideas for them."* Research that **stocks** the pool — pulling
onto a trip stays manual, so it feels safe.

The organizing principle is unchanged from the 2026-06-22 design chat and
PRODUCT.md: **AI stocks and understands the pool; it never pulls onto a trip or
decides the trip** (ADR-0004's explicit-pull boundary, ADR-0013's candidate-vs-pulled
distinction). The main risk is **discovery quality** — does "all Michelin in the
Loire" actually return the right set? — which is why slice 0 is a throwaway spike
that gates the rest.

What already exists to build on: the `ModelClient` boundary + `AnthropicModelClient`
/ `AnthropicWire` (M6a/ADR-0014); the `PlaceMatcher` MapKit resolution ladder and
`PlaceMatching.score` overlap scoring (M4b/c); `MapRegion.contains(latitude:longitude:)`
(M2c); `PlaceEnricher` (M4g); `Idea.Draft` + save (M4b).

## Decision

### 1. Generation — one grounded `complete()` call, app owns persistence

Discovery is **one `ModelClient.complete()` frontier call with web search enabled**,
instructed to return a **strict JSON array** of candidates
(`name`, `kind`, `locality`, `region`, `note`, `sourceURL`). The app parses the
array and owns dedup + persistence — **the model finds and structures; it never
writes.** This is simpler and more testable than a client-side tool-use loop for a
batch fetch; the `findPlaces` App-Intent verb wrapper (the composable-substrate
payoff in the BACKLOG entry) comes later, not in this slice.

**Frontier-only, BYO-key.** On-device `FoundationModels` cannot web-search, so
discovery requires the frontier tier with the user's own key (ADR-0014). No key →
discovery unavailable. This holds no-server (ADR-0001): web search is Anthropic's
server-side tool, invoked through the user's own key, not infra Jon runs.

### 2. Resolution + dedup — reuse the M4 place stack

Each candidate's `name` + `locality` goes through **`PlaceMatcher.match()`** (the
M4b/c MapKit signal ladder) to get a coordinate + canonical fields, then is deduped
against the existing pool via **`PlaceMatching.score`** (name/street overlap) +
coordinate proximity. A **pure, tested `DiscoveryDedup` core** classifies each
candidate as `.new` / `.duplicate(Idea.ID)` / `.nearMatch(Idea.ID)`. Dedup is the
non-obvious essential — don't re-add places already saved; flag near-matches.

### 3. Bucketing + persist

`MapRegion.contains(latitude:longitude:)` auto-buckets survivors into the right
region; each becomes an `Idea.Draft` → `Idea.save(...)`, born as a **candidate** (a
pool idea on no trip — ADR-0013, **no new table for v1**). Optional best-effort
`PlaceEnricher` pass for image/notes after save. A candidate pin-less because
`PlaceMatcher` couldn't resolve it is acceptable (saved without a coordinate).

### 4. UI

A **region-scoped themed-search entry**; results reviewed as a list + candidate-tinted
pins on `PoolMapView` (reuse ADR-0013's candidate styling); **Add all / selected**.
Jon dispositions candidates on the map exactly as today — AI is a third, tireless
source feeding the pool alongside share-extension capture and manual entry.

**Dev spike entry point (Jon's call, 2026-06-23):** the slice-0 spike lives behind a
**small, easy-to-delete entry on the Ideas screen toolbar** — *not* a separate
throwaway debug view. Easy to delete once the spike has served its purpose.

### 5. Wire change (`GalavantAI`) — needs the `claude-api` skill first

- `ModelRequest`: add a web-search flag (likely `webSearchMaxUses: Int?`).
- `AnthropicWire.requestData`: emit the server tool
  `{"type":"web_search_20250305","name":"web_search","max_uses":N}`.
- `AnthropicWire.response`: tolerate `server_tool_use` / `web_search_tool_result`
  blocks (server-executed — we ignore them) and still capture the final text.
  **Non-streaming `complete()` only**; no streaming needed for a batch fetch.
- Unit-test request assembly + response parsing with the existing stub backend (no
  network). Confirm the exact tool block + model IDs against the **`claude-api`**
  skill before writing — past Claude's cutoff.

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **Client-side tool-use loop** (model calls a `findPlaces` tool, app runs it, returns results) | Deferred, not chosen for v1. A single grounded `complete()` returning a JSON batch is simpler and more testable; the App-Intent verb vocabulary is the later composable payoff, not this slice. |
| **On-device discovery** | Rejected. `FoundationModels` structures a *known* place well but is not a web-search index; discovery needs live web search → frontier-only. |
| **A new `Candidate` table** | Rejected for v1. ADR-0013 already models candidate-vs-pulled; a candidate is just a pool `Idea` on no trip. No schema change. |
| **Skip dedup / trust the model not to repeat** | Rejected. Re-adding saved places is the obvious failure; dedup against the pool (`PlaceMatching` + proximity) is essential, and a pure tested core. |
| **Google SERP scraping for discovery** | Rejected (carried from ADR-0016) — ToS-hostile, brittle. Anthropic web search through the user's key is legitimate and robust. |
| **One grounded `complete()` + reuse the M4 resolve/dedup stack + candidate Ideas (chosen)** | Reuses the proven place pipeline, stays no-server + BYO-key, keeps AI-stocks-never-decides crisp, and gates quality with a cheap spike before investing in UI. |

## Relationship to prior decisions

- **ADR-0004 / ADR-0013 (explicit pull / candidate-vs-pulled):** discovery lands
  **candidates**; pulling onto a trip stays manual. AI stops exactly where the pull
  boundary is. No new table — a candidate is a pool idea on no trip.
- **ADR-0014 (model access):** frontier tier + the user's own key; web search is a
  device-local, BYO-key capability, never infra Jon runs.
- **ADR-0001 (no server):** Anthropic's server-side web-search tool invoked through
  the user's key holds the no-server line.
- **M4b/c/g (the place pipeline):** `PlaceMatcher` / `PlaceMatching` / `PlaceEnricher`
  are reused for resolution, dedup, and post-save enrichment.
- **ADR-0016 (no SERP scraping):** carried forward.

## Consequences

- **`GalavantAI`:** `ModelRequest.webSearchMaxUses`; `AnthropicWire` emits the
  `web_search` server tool and tolerates `server_tool_use` / `web_search_tool_result`
  blocks; request-assembly + response-parse tests against the stub backend.
- **`GalavantPlaces`:** a `PlaceDiscoveryClient` (grounded `complete()` + JSON parse);
  a pure `DiscoveryDedup` core (`.new` / `.duplicate` / `.nearMatch`); the
  resolve → dedup → bucket → batch-save → optional-enrich orchestrator. (Add a
  `GalavantAI` dep to `GalavantPlaces` in `project.yml` if missing →
  `xcodegen generate`. No new SPM target expected.)
- **App:** a region-scoped discovery entry + candidate review (list + tinted pins on
  `PoolMapView`) + add-to-pool; the slice-0 spike behind a small, deletable Ideas-
  toolbar entry.
- **Gated at the spike (slice 0):** whether "find ALL X" returns a complete, accurate,
  fresh set. Good → build slices 1–4; weak → tune prompt/search before investing in
  dedup + UI. **This ADR is `proposed` until that gate passes.**
- **Open / risks:** `web_search` cost + latency (bounded by `max_uses`); MapKit
  resolution misses for obscure places (pin-less candidate — acceptable); ATS.

## Slices (operational detail in `docs/M6-EXECUTION.md`)

- **Slice 0 — the spike:** the `web_search` wire change + a `PlaceDiscoveryClient`
  doing the grounded `complete()` + JSON parse; a dev-only Ideas-toolbar entry that
  dumps the raw candidate list (names, localities, sourceURLs) — no dedup, no save.
  Tests: request-assembly + JSON parse against the stub. **Jon runs the live call
  on-device** for "all 2–3★ Michelin in the Loire" and eyeballs the result. **Decision
  gate.**
- **Slice 1 — dedup core (pure, tested):** `DiscoveryDedup` + `MapRegion` bucketing;
  fixture tests (exact dup, near-match, distinct, junk).
- **Slice 2 — resolution + persistence:** `PlaceMatcher` resolve → dedup → batch
  `Idea.save` → optional enrich; tested with an in-memory DB + fixture matcher.
- **Slice 3 — the real UI:** region-scoped discovery entry + candidate review (list +
  tinted pins) + add-to-pool. `swiftui-specialist` checkpoint.
- **Slice 4 — docs:** finalize this ADR (flip to accepted), the M6-EXECUTION brief,
  ROADMAP/BACKLOG updates.
