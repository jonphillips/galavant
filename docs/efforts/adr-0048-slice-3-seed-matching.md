# Effort — ADR-0048 Slice 3: seed matching (saved ideas, then the map)

**Status:** Parked (2026-10-06): Jon moved backup ahead of it (ADR-0049 S1). Re-dispatched by the architect after S1 · **Summary:**
[ADR-0048](../decisions/0048-trip-seed-handoff.md) D7. Inside the seed review, before Import:

1. match each stay and place against the party's **saved ideas**, then the **map**;
2. let **one tap confirm the obvious matches**;
3. resolve confirmed rows through the existing capture merge as part of the import;
4. turn `place_notes` into `IdeaEvaluation`s on resolved places.

Leftover unresolved rows stay freeform and open in the ADR-0037 workspace. No schema change and no
new ingestion path.

## Pure core (test-first)

### Match keys and saved-idea matching (GalavantSchema)

- `SeedMatchKeys(row)` builds two keys:
  - `name`;
  - the first comma-separated segment of `search_hint`.

  Strip trailing company suffixes (`ApS`, `A/S`, `I/S`, `GmbH`, `Ltd`, case-insensitive), then
  normalize with `RecommendationCandidateIdentity.normalized`. Drop empty or duplicate keys. Test it:
  "DYVIG BADEHOTEL ApS" and "Dyvig Badehotel, Nordborg, Denmark" both yield `dyvigbadehotel`;
  "Ruth's Hotel" yields `ruthshotel`.
- `SeedPoolMatch.match(keys:locality:ideas:) -> SeedPoolMatch`, with outcomes `.idea(Idea)`,
  `.ambiguous([Idea])`, `.none`.
  - A pool idea matches when its normalized `name` equals any key.
  - When the row has a `locality` and the idea has an `address`, the normalized address must contain
    the normalized locality. Same rule as `RecommendationCandidateSet.liveTripIdea`.
  - Two or more matches → `.ambiguous`, never auto-picked.

### Map matching and "obvious" (GalavantPlaces)

- The search is the existing `PlaceMatcher.matches(for: TripCandidate, in: tripRegions)`, which is
  region-biased and worldwide when the trip has no regions. Run it only for rows with no saved-idea
  match. **At most 4 searches at once**; a seed can carry 40 rows and MapKit throttles.
- `SeedMatching.obviousChoice(keys:results:) -> Place?` (pure):
  - A result **covers** a key when every significant word of the key appears in the result's name.
    Use `PlaceMatching.significantCommonWordCount`'s notion of significant: no numbers, no short
    tokens.
  - Return the result only when **exactly one** result covers some key. Otherwise `nil`, and the row
    shows its results as choices.
  - This respects `PlaceMatcher`'s rule that recommendation resolution "must show choices, never
    auto-select one". `obviousChoice` only pre-selects. The human's **Confirm Obvious Matches** tap
    (or a per-row pick) is the selection.
- **Identity pre-check:** if a map result's `mapItemIdentifier` equals a pool `Idea`'s, treat the
  row as a saved-idea match for that idea.

### Collision pre-check (GalavantSchema)

- If a row's matched pool idea **already has a live `TripIdea` on this trip** (not counting the row
  being created), the row becomes **Already on trip as "<title>"**: excluded by default and never
  attached.
- That keeps the one-transaction import free of `ResolveReconcile` collisions, which need a human
  choice the bulk sheet can't ask for. Map matches are checked through the identity pre-check above.
- If `RecommendationResolution.confirm` still returns a collision at commit (no `mapItemIdentifier`
  in the pool), **don't apply it**. Detach with `TripIdea.detachResolvedIdea(…, deletingOrphanedIdea:
  true)`, leave the row unresolved, and list it in the post-import summary ("resolve in Evaluate").

## Review (extends Slice 2's `SeedReviewSheet`)

- **Row badges:** *Saved idea* · *Map match* · *Choices (n)* · *Unresolved* · *Already on trip as …*.
  Matching runs when the review opens and fills in asynchronously; Import stays enabled throughout.
  Rows still searching import unresolved.
- **"Confirm Obvious Matches"** (one tap) confirms every *Saved idea* and *Map match* row. Each row
  can also be confirmed or unconfirmed on its own, and *Choices* rows offer an inline picker.
  Unconfirmed rows import unresolved, exactly as in Slice 2.
- **Kept out of the feature model:** the async search state lives in a small injected seam (a
  dependency client wrapping `PlaceMatcher`), so the model stays thin and the pure functions above
  carry the logic (watch for fat models).

## Commit changes (inside Slice 2's single transaction)

- **Confirmed stay:** `TripStay.create(… ideaID: …)` instead of `createFreeform`.
  - Saved-idea match: use that idea.
  - Map match: first resolve the place through the capture merge (`Idea.resolveCapture` with
    `place.ideaCapture()`, the path `RecommendationResolution.confirm` uses) to get the idea ID.
- **Confirmed place:**
  - Saved-idea match: `TripIdea.attachResolvedIdea`.
  - Map match: `RecommendationResolution.confirm(candidateStopID:capture:)`, applying the collision
    rule above.
  - Pass the row's normalized seed kind as the capture's kind **only when the map result has
    none**.
- **`place_notes` on resolved rows:**
  - Write `IdeaEvaluation.create(travelPartyID:ideaID:sourceName: "Trip research", kind: .text,
    nativeValueText: <notes>, nativeDisplay: "Research note", evaluationDate: now, confidence:
    .inferred, staleness: .current, summary: <notes>)`.
  - **Leave** the `About the place:` paragraph off that row's `inlineNote`. Slice 2's note composition
    takes a `resolved: Bool`.
  - Unresolved rows keep the paragraph, so nothing is dropped.
- **Deferred rows that resolve** reach the pool, so they show on the Ideas map for future trips.
  This is the point of ADR-0048 D5.

## Leftovers in the workspace

- `mostRecentRecommendationWorkspaceSession` (and the readiness check) accepts `taskType == seedTrip`
  as well as `candidatePlaces`, so **Evaluate Recommendations** opens a seed's unresolved
  `.considering` rows.
- Unresolved **`.declined`** rows don't appear in the Evaluate queue, which shows `.considering`
  only. Resolving a ruled-out row later belongs to a follow-up in `docs/open-questions.md`. Not this
  slice.

## Tests

- Keys (suffix stripping, the hint segment, dedup).
- Saved-idea match:
  - equal name, with and without a locality conflict;
  - ambiguous;
  - identity pre-check by `mapItemIdentifier`.
- `obviousChoice`:
  - one covering result → picked;
  - two → `nil`;
  - none → `nil`;
  - numbers and short tokens ignored.
- Collision pre-check against a live row.
- **Commit with an injected matcher**, on the Denmark fixture with a pool seeded with "Dyvig
  Badehotel" and "Restaurant ND122":
  - Dyvig confirms as a saved idea under its ApS name and lands `.declined` with `ideaID` set;
  - the deferred row's evaluation is written and its note has no `About the place:`;
  - ND122 already shortlisted on the trip → *Already on trip*, untouched;
  - an unresolved row keeps its `About the place:` paragraph;
  - a forced collision detaches and lists.
- Workspace availability for a `seedTrip` session.

## Done when

- One PR on branch `effort/adr-0048-slice-3`. `scripts/check-drift.sh` green, plus headless
  `GalavantTests`.
- No schema change. Presentations stay hosted in `TripDetailPresentationHost`.
- The completing PR:
  - adds a DONE-LOG entry;
  - marks this brief Done;
  - sets `docs/NEXT_UP.md` to `Nothing dispatched.`;
  - adds to `docs/open-questions.md`: *Resolve a ruled-out row: Ruled out rows can't reach the
    Evaluate queue, so an unresolved deferred place never reaches the pool. Offer "Find on Map" from
    the Ruled out section.*;
  - adds to `docs/device-passes.md`: *seed the Denmark conversation into a trip that shares a few
    places with the pool: saved-idea matches badge correctly (including any business-listing names),
    "Confirm Obvious Matches" resolves the expected rows, deferred places appear on the Ideas map,
    research notes show on the resolved places, and Evaluate opens the leftovers.*
