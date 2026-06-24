# ADR-0019: MapKit identity on ideas — capture dedup and supplement

*Status: accepted — 2026-06-23*

## Context

Re-sharing the same place makes a second pool `Idea`. Today capture mints a fresh
`UUID()` per share and inserts unconditionally — there is no "do we already have this
place?" check, and nothing in the pipeline carries a stable place identity to check
*against*:

- `Place.init(mapItem:)` ([PlaceSearch.swift]) keeps name/coords/address and throws
  away `MKMapItem.identifier`.
- `LocationMatch` ([PlaceMatcher.swift]) — the enriched match the capture flow
  resolves — has no identifier field either.
- `Idea` ([GalavantSchema/Idea.swift]) has no MapKit-ID column.
- `CaptureModel.persistCapture()` ([GalavantPlaces/CaptureModel.swift]) does an
  unconditional `Idea.insert { … }`.

The user instinct that motivates this: *"if I share a place I already have, recognize
it and supplement the existing idea rather than duplicate it."* That is exactly the
confirm-and-tweak / facts-vs-judgments machinery ADR-0016 already built — it just has
no identity key to hang dedup on. As of iOS 26 `MKMapItem.identifier` is a *persistent*
identifier for a place (a `String` raw value), which is a far more reliable match key
than fuzzy name/coordinate comparison.

This is the natural successor to ADR-0016 (source-aware capture + field supplement):
0016 enriches a place; 0019 keeps us from holding the same place twice.

## Decision

### 1. Thread the stable MapKit identifier through the identity chain

Persist Apple's place identity so "same place" is an exact lookup, not a heuristic.

- **`Place` gains `mapItemIdentifier: String?`**, populated in `init(mapItem:)` from
  `item.identifier?.rawValue` (iOS 26 `MKMapItem.Identifier`; verify the spelling
  against the Xcode-beta SDK headers per `apple-sdk-headers-authoritative` — past
  Claude's cutoff). Nil when the platform gives no identifier (geocoded address,
  scraped-coordinate, or freeform match).
- **`LocationMatch` gains `mapItemIdentifier: String?`**, carried from the matched
  `Place` so the capture flow sees it.
- **`Idea` gains `mapItemIdentifier: String?`** (and `Idea.Draft` follows). A new
  nullable column via a `migrator.registerMigration` `ALTER TABLE` step, exactly like
  the ADR-0016 hours columns. **No `UNIQUE` constraint** — dedup is an application-level
  lookup, not a schema invariant (CloudKit has no cross-device uniqueness, and a hard
  constraint would reject a legitimate offline-twin sync; see Open questions).

### 2. Capture recognizes a known place and routes to *supplement*, not insert

In `CaptureModel`, once the place is matched, look up an existing pool idea with the
same `mapItemIdentifier`:

- **Match found → supplement path.** Don't insert. Surface it in the confirm sheet
  (M4c ethos — never silent): *"Already in your pool — update it?"* with the existing
  idea named. On confirm, **merge into the existing `Idea`** rather than creating a new
  row, then pull *that* idea onto the selected trip (idempotent — `TripIdea.pull` is
  already safe).
- **No match (or no identifier) → today's behavior**, unchanged: insert a new idea.
  We deliberately do **not** auto-merge on a nil identifier — a name/coordinate guess
  is exactly the false-merge risk we're avoiding. (A *soft* "is this the same as X?"
  suggestion for near-coordinate hits is a possible later rung, explicitly out of v1.)

### 3. Merge semantics — confirm-and-tweak, facts vs judgments (inherit ADR-0016)

The merge is the same fill-blanks-only rule capture already uses against Apple Maps,
applied idea↔idea:

- **Facts on `Idea`:** fill fields the existing idea left blank
  (`address`/`phone`/`regionName`/`kind`/`url`/coordinates, and `openingHours` with its
  provenance/staleness stamp). **Never clobber** a value already present — a deliberate
  edit or a verified fact stands. Stamp the MapKit identifier if the existing row
  lacked one (back-fills identity onto pre-0019 ideas on their next re-share).
- **Judgments stay siblings (ADR-0015/0016):** newly detected `IdeaEvaluation`s append
  to the existing idea (many evaluations are allowed); a re-share of the same source
  de-dups on (source, kind, value) so a second Michelin capture doesn't double the
  stars.
- **Images:** add the captured header only if the existing idea has none; don't
  displace a chosen header.

The merge is a pure function over (existing `Idea`, captured draft + evaluations) so it
is unit-testable in `GalavantPlaces` with an in-memory DB, the way the capture tests
already run.

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **Fuzzy name + coordinate dedup** | Rejected as the key. Brittle and false-merge-prone (two restaurants in one building; a hotel and its bar). MapKit's persistent identifier is the exact, Apple-blessed key; fuzzy matching is at best a *soft suggestion* rung, not the v1 mechanism. |
| **`UNIQUE(mapItemIdentifier)` DB constraint** | Rejected. CloudKit can't enforce cross-device uniqueness, and a local hard constraint would reject a legitimate offline twin at sync time. Dedup is an app-level lookup; the column is plain nullable. |
| **Dedup silently at save** | Rejected. Violates the M4c "vet at the source" ethos — the user should see "you already have this; updating it." Silent merges hide data changes. |
| **Auto-merge when identifier is nil** | Rejected for v1. No stable key means a guess; the whole point is to avoid wrong merges. Nil → insert (today's behavior). |
| **Merge by overwriting the existing idea** | Rejected. Breaks confirm-and-tweak and the facts-vs-judgments split; a re-share could stomp a verified fact or a hand edit. Fill-blanks-only. |
| **Thread identity + lookup + fill-blanks merge, surfaced in confirm (chosen)** | Reuses ADR-0016's confirm sheet and merge ethos, stays no-server (a DB lookup), and keeps a crisp exact-key dedup with no false merges. |

## Relationship to prior decisions

- **ADR-0016 (source-aware capture + supplement):** direct successor. The merge reuses
  0016's fill-blanks-only facts path and its evaluation de-dup; the confirm sheet is the
  same surface. 0016 enriches a place; 0019 stops us duplicating it.
- **ADR-0015 (evaluations):** re-shared ratings append as siblings on the existing
  idea, honoring the loose-`ideaID` / many-evaluations model.
- **ADR-0001 (no server):** dedup is a local DB lookup; nothing new runs server-side.
- **ADR-0003 (shared travel party):** the lookup is scoped to the party's pool, so a
  merge stays within the shared data the capture already writes.
- **ADR-0007 (attribution/sharing FKs):** merging into the existing idea preserves its
  FKs and CloudKit share membership — no new record, no re-attribution.
- **ADR-0018 (AI pool-stocking discovery):** distinct and complementary — 0018 *finds*
  new places to add; this ADR keeps a place from being added twice. Discovery results
  that resolve to a Maps POI flow through the same `mapItemIdentifier` dedup here.

## Consequences

- **`GalavantPlaces` / `GalavantSchema`:** `mapItemIdentifier` added to `Place`,
  `LocationMatch`, `Idea`/`Idea.Draft`; one `ALTER TABLE … ADD COLUMN` migration.
- **`CaptureModel`:** a pre-save existing-idea lookup by identifier; a `Phase` /
  confirm-sheet branch for "update existing vs create new"; a pure `merge` over the
  existing idea. Capture-flow tests gain a duplicate-share fixture (same identifier →
  one row, facts back-filled, evaluations de-duped).
- **Confirm sheet (extension):** a "already in your pool — update it?" state with the
  matched idea named; default action confirms the supplement.
- **Back-fill:** pre-0019 ideas have a nil identifier until their next re-share stamps
  one; dedup strengthens over time rather than needing a migration backfill.
- **Open questions / out of v1:**
  - **Offline twins.** Two devices capturing the same place while offline still make
    two rows (no cross-device uniqueness). A later *dedup-on-read*/merge-duplicates
    pass (by identifier) is the answer; out of scope here.
  - **In-app "add to pool" search-first capture** (not just the share extension) should
    route through the same lookup — confirm the search path stamps the identifier too.
  - **Soft near-coordinate suggestion** for the nil-identifier case — a possible later
    rung, deliberately excluded now to keep dedup false-merge-free.
  - **Identifier stability/format** on iOS 27 — verify `MKMapItem.identifier` /
    `MKMapItem.Identifier.rawValue` at build against the SDK headers.
