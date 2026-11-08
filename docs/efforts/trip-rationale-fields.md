# Effort — On this trip: keep Chat's visit, why and fit, and show them before Taste Notes

**Status:** Ready · **Summary:** [ADR-0055](../decisions/0055-trip-rationale-fields.md). `TripIdea` gains `rationaleVisit`,
`rationaleWhy` and `rationaleFit`. Import writes them instead of packing them into `inlineNote`, and existing rows are
backfilled from this device's hand-off history. The dossier shows an "On this trip" section wherever it has a trip,
including the guide. Taste Notes go to the bottom until the place has been visited. **Adds synced columns: a CloudKit
deploy is owed before TestFlight.**

**Read first:** ADR-0055; ADR-0036 D3 and ADR-0037 D4 (the rationale survives resolution); jon-platform
`docs/ios/persistence-and-sync.md` § Adding a synced table or column; ADR-0053 (the dossier and taste notes).

**Depends on `day-design-sheet`** only for ordering. The code doesn't overlap.

## Today

- `TripCandidate` has `why`, `fit` and `visit`. Its `rationale` is why plus fit.
- `TripIdea.commit(candidate:into:in:)` (`RecommendationHandoff.swift`) writes `inlineNote: candidate.rationale`. `visit`
  is lost. Every candidate path reaches it through `RecommendationSetImport` (Evaluate, the MCP inbox, pasted returns).
- `SeedPlacePlan.note(resolved:)` (`SeedPlan.swift`) packs why, fit, visit, the reason or deferral, and place notes into
  one note.
- `RecommendationEvaluation` merges a duplicate's `inlineNote` with `mergedNote(existing:duplicate:)`.
- `HandoffSession` (LLMHandoffKit, stored on the device by `HandoffSessionStore`) keeps `candidatePayload` and
  `candidateLinks` (candidate id to `TripIdea` id).
- `IdeaDetailView` takes `whyOnTrip: String?`. `TripDetailContent` passes `rationaleForDetail()` (the stop's
  `inlineNote`). `RegionGuideScreen` and `IdeaMapSplitView` pass nothing.
- `IdeaDossier.emphasis` (`Emphasis.forKind`) puts Taste Notes first for stays and after accolades and interests for
  everything else.

## Part 1. Schema

- Append a migration that adds three nullable `TEXT` columns to `tripIdeas`: `rationaleVisit`, `rationaleWhy`,
  `rationaleFit`. Add the properties to `TripIdea` and its init with `nil` defaults.
- Update `cloudkit-expected-fields.txt`.
- Check every place that copies a `TripIdea` field by field (duplication, alternatives, restore, chat export) and carry
  the three fields wherever `inlineNote` is carried.

## Part 2. Write paths

- `commit(candidate:)` writes the three fields from `visit`, `why` and `fit`, and leaves `inlineNote` nil.
- Seed import writes the three fields from the place's candidate. `note(resolved:)` keeps only the reason or deferral and
  the place notes.
- On a duplicate merge, merge each field with the same `mergedNote` rule as `inlineNote`.
- Candidate matching stays the same. When a match finds an existing live stop, fill any of its empty fields from the
  candidate, but never overwrite a non-empty one.

## Part 3. Read-model and dossier

```swift
public struct TripRationale: Equatable, Sendable {
  public var visit: String?
  public var why: String?
  public var fit: String?
  public var note: String?          // the stop's inlineNote
  public var isEmpty: Bool
}
extension TripIdea { public var rationale: TripRationale { … } }
```

- `IdeaDetailView` replaces `whyOnTrip: String?` with `tripRationale: TripRationale?`. When it isn't empty, an
  **"On this trip"** section goes right after the overview (header photo, identity, Visited), before Taste Notes and
  accolades. It shows labeled rows Visit, Why, Fit, then Note, each with `textSelection(.enabled)`, skipping empty ones.
- **Trip detail:** pass the scheduled stop's rationale (replacing `rationaleForDetail()`).
- **Guide:** when the lens has a trip, `RegionGuideModel` finds that trip's stop for the dossier's idea and passes its
  rationale. If there are several stops, prefer the scheduled one, then the effective-active ring member, then any. Thread
  it through `IdeaMapSplitView` (iPad panel) and the iPhone sheet. With no lens trip, there's no section.
- **Taste Notes placement.** Replace `Emphasis` with `IdeaDossier.notesPlacement` (`.top` or `.bottom`), computed from
  the idea and its stops across trips and `now`. `.top` when `Idea.visited`, or a stop has `completedAt`, or a scheduled
  stop with no `skippedAt` is on a dated trip whose day's date is before today. Otherwise `.bottom`, after tags and notes.
  Accolades and interests keep their current order.

## Part 4. Backfill (local to the device, idempotent)

A pure function decides each row, and a launch task applies it:

```swift
public enum TripRationaleBackfill {
  /// The fields to write, or nil to leave the row alone.
  public static func update(for stop: TripIdea, from candidate: TripCandidate) -> TripRationale?
}
```

- It applies only when the stop's three fields are all empty and `stop.inlineNote` equals `candidate.rationale`
  (whitespace-trimmed) or is nil while the candidate has a `visit`. The write sets the three fields and clears
  `inlineNote`.
- Seed sessions: use them only if the session keeps the seed return in a form that rebuilds the old packed note exactly.
  Otherwise skip seed rows and say so in the PR.
- Run it once per launch after the database opens, over `HandoffSessionStore.sessions()` and their `candidateLinks`.
  It's a no-op the second time, so it needs no flag.

## Tests

- Migration: the columns exist, and old rows read as nil.
- `commit(candidate:)` and seed import write the fields; `inlineNote` keeps only the non-rationale parts.
- Merge: each field merges, and a match fills empty fields without overwriting.
- `TripRationaleBackfill`: exact match writes; an edited note is left alone; filled fields are left alone; running twice
  does nothing new.
- `notesPlacement`: each visited signal gives `.top`; a future, skipped or undated stop gives `.bottom`.

## Done when

- `scripts/check-drift.sh` is green, plus headless app-target tests.
- `cloudkit-expected-fields.txt` lists the three fields.
- NEXT_UP's **Owed** line and closeout name the deploy: import `rationaleVisit`, `rationaleWhy` and `rationaleFit` on
  `tripIdeas` with `cktool` and deploy to Production before the TestFlight build.
- Device gate: Erst (Manchester) shows Visit, Why and Fit in the guide's dossier, above Taste Notes, after the backfill;
  a newly imported candidate shows all three; Taste Notes sit at the bottom for an unvisited place and at the top for a
  visited one.
