# Effort — ADR-0048 Slice 1: `.declined` status + trip documents

**Status:** Done (2026-10-04), implementation in `effort/adr-0048-slice-1` · **Summary:** the
two schema pieces of [ADR-0048](../decisions/0048-trip-seed-handoff.md) (trip seed handoff) that are
useful without the seed. One is a way to rule a place out of a trip and keep the reason. The other is
a synced, read-only Markdown document attached to a trip. **No seed verb, no contract change, no
matching**; those are Slices 2–3.

This is a **schema + sync** change: one new `TripIdeaStatus` case and one new synced table. The
architect escalates the PR to Jon before merge (jon-platform `AGENTS.md`).

## Part A — `TripIdeaStatus.declined`

ADR-0048 D5 is the spec. Summary: **considered for this trip and ruled out, with the reason kept.** It
is a pre-trip end state, distinct from `.skipped` (post-trip "didn't do it", which feeds visited
state).

### Schema (GalavantSchema, test-first)

- Add `case declined = 5` to `TripIdeaStatus` ([TripIdeaStatus.swift](../../GalavantLibrary/Sources/GalavantSchema/TripIdeaStatus.swift)).
  Never renumber. `label` → `"Ruled out"`. `isOnShortlist` → `false`. Update the type's doc comment
  (it currently says `done`/`skipped` are the only terminals).
- No migration: the column is an `INTEGER` already. Old builds that read a `5` are a real concern
  only across Jon's own devices; note it in the PR and make sure both devices update together.
- **`TripOperations`** ([TripOperations.swift](../../GalavantLibrary/Sources/GalavantSchema/TripOperations.swift)):
  - `decline(stopID:reason:in:)`: only from `.considering` or `.shortlisted` (a scheduled stop must be
    unscheduled first, the same rule as remove). Sets `.declined`. A non-blank `reason` is appended to
    `inlineNote` as a new paragraph, `"Ruled out: <reason>"`, separated by a blank line (the
    ADR-0026 additive-notes rule: never overwrite the AI rationale already there). If the stop is in an
    alternatives ring, it leaves the ring exactly as removing a member does; reuse that op.
  - `setStatus(_:stopID:in:)`: handle `.declined` in its switch by routing to `decline(… reason: nil)`.
    Moving a `.declined` row back to `.considering`/`.shortlisted` is an ordinary status change; the
    note is kept as history.
  - Add a pure `ruledOut(_ entries:)` next to `considering(_:)`, sorted by title.
  - **Pull must reuse the row.** Pulling (consider or shortlist) an idea that already has a `.declined`
    row on this trip flips that row's status and keeps its note. It **never** inserts a second
    `TripIdea`. Add a test for it.
- **Every exhaustive `switch` over the status** gets `.declined`. The current sites and the intended
  value:
  - `IdeaTripBadge.badge`: `nil`, like `.skipped` (a negative signal, not an association to advertise).
  - `RecommendationEvaluation` (both switches): treated like `.done`/`.skipped` (not open; sorts last).
  - `RecommendationCandidateMatching.isLive`: **`true`**. A re-pasted candidate with the same name as a
    ruled-out row must not mint a duplicate `.considering` row. It links to the declined row, which
    stays declined.
  - `IdeasListModel.activeTripStage`: `nil` (shows as not on the trip; pulling it reuses the row, above).
  - `TripPlanningModel.tapConsidering` / `tapShortlist`: `.declined` behaves like `nil` (pull), which
    reuses the row via the rule above.
  - The compiler will find the rest. Treat each as off-trip and not visited unless this brief says
    otherwise.
- **The handoff brief lists what's ruled out.** `RecommendationHandoffContract.brief`
  ([RecommendationHandoff.swift](../../GalavantLibrary/Sources/GalavantSchema/RecommendationHandoff.swift))
  gains a section after the stops, present only when non-empty:
  ```
  Already ruled out (don't suggest again):
  - Alsik (Sønderborg) — Ruled out: too large and corporate for this trip.
  ```
  Title uses the same `description(for:)` as the stop summary. The note is `inlineNote` folded to one
  line and truncated to 160 characters with `…`; with no note, it's the title alone. Extend the
  signature in whatever way fits; keep `stopSummary` unchanged.
- ADR-0030 in-app suggestions are not built. Nothing to filter yet.

### UI

- **"Rule Out…"** in the menus of considering and shortlisted rows. `TripIdeasView` has the
  `Remove` actions (around lines 106, 155, 268); put it next to them. It opens an alert with an
  optional reason `TextField` and calls `decline`.
- A collapsed **"Ruled out (N)"** `DisclosureGroup` after the Considering group on the trip's Ideas
  view. Rows show title + note (two lines, truncated). Row action: **Reconsider** → `.considering`.
  Hidden when N = 0.
- `.declined` rows appear nowhere else: not on the shortlist, the itinerary, To Be Scheduled, Today,
  Journey, the booking rollup, or the Evaluate queue. Most of these filter on `isOnShortlist` or
  `.scheduled` already; confirm each with a schema test where a pure projection exists.

## Part B — `TripDocument`

ADR-0048 D6 is the spec.

### Schema

- New `@Table` `TripDocument` in GalavantSchema: `id`, `tripID`, `title`, `body`, `origin`,
  `createdAt`. `origin: TripDocumentOrigin` is an `Int`-backed enum: `seed = 0`, `pasted = 1`,
  never renumbered. Only `.pasted` is written in this slice.
- Migration `"Create tripDocuments table (ADR-0048)"`, following the `tripStays` pattern in
  [Database.swift](../../GalavantLibrary/Sources/GalavantSchema/Database.swift): `STRICT`, `tripID`
  `REFERENCES "trips"("id") ON DELETE CASCADE`, index on `tripID`.
- **Register in `GalavantCloudSync.makeSyncEngine`'s `tables:` list.** It is a synced table.
- `TripDocumentOperations`: `add(tripID:title:body:origin:now:)`, `rename(_:title:)`, `delete(_:)`.
  `add` throws a typed `TripDocumentError.tooLarge` when `body.utf8.count > 512_000` (loud, well
  under CloudKit's 1 MB record limit) and `.emptyBody` for whitespace-only bodies. A blank title
  defaults to `"Document — <date>"`. Use `@Dependency(\.date)` / `\.uuid` per house style.
- Tests (in-memory): add/rename/delete; cascade on trip delete; both errors; ordering newest first.

### UI

- **"Documents"** in the trip's "···" menu (the menu holding Sketch, `TripPlanningView.swift`
  around line 125) presents a sheet via the trip's `Destination` enum (no `isShowingX` booleans).
- **List:** title, created date, newest first. Swipe or menu: Rename, Delete (with confirmation).
  Empty state: "Paste research notes or a Chat summary to keep them with this trip."
- **Add:** a sheet with a Title field and a `TextEditor` for the body (paste), plus **Import File…**
  (`fileImporter` for plain text and `.md`; the title defaults to the file name without extension).
  Save calls `add(… origin: .pasted)` and surfaces `tooLarge`/`emptyBody` as alerts.
- **Viewer (read-only):** a `ScrollView` with `Text(AttributedString(markdown:options:))` using
  `.inlineOnlyPreservingWhitespace`, falling back to the raw string if parsing throws.
  `.textSelection(.enabled)`. Headings and tables show as their raw Markdown lines. That is the
  agreed floor for ADR-0048 OQ1. **Do not add a Markdown dependency.**
- Feature model stays thin. Validation and ordering live in the schema ops above.

## Out of scope

The seed verb, contract v2, `SeedPlan`, the bulk review, matching, `IdeaEvaluation` writes,
documents as chat or brief context, and editing a document's body.

## Done when

- One PR on branch `effort/adr-0048-slice-1`.
- `scripts/check-drift.sh` green, plus headless `GalavantTests` (app models touched), per
  `docs/verification.md`.
- New schema tests cover:
  - the raw value 5;
  - `decline` (reason appended, ring exit, scheduled refused);
  - pull reusing a declined row;
  - `ruledOut`;
  - shortlist, itinerary and booking-rollup exclusion;
  - the brief's ruled-out section (present, absent, truncation);
  - `isLive`;
  - the `TripDocument` ops and errors.
- The PR description flags **schema + sync** for escalation and names the owed device gates.
- The completing PR:
  - adds a DONE-LOG entry;
  - sets `docs/NEXT_UP.md` to `Nothing dispatched.` (Slice 2 is dispatched by a later plan PR);
  - marks this brief Done in `docs/efforts/README.md`;
  - adds to `docs/device-passes.md`:
    - *a document added on one device appears on the other after sync, and deleting the trip removes
      it;*
    - *a place ruled out on one device shows under Ruled out on the other;*
    - *CloudKit: promote the `tripDocuments` record type to Production before the next TestFlight
      build.*
