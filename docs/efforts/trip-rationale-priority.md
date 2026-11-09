# Effort — Keep Chat's priority: "Chat's #2 of 5"

**Status:** Ready · **Summary:** [ADR-0055](../decisions/0055-trip-rationale-fields.md) D7. The hand-off contract says what
`priority` means (1 is Chat's first choice, ranked within this list). `TripIdea` gains `rationalePriority` and
`rationalePriorityOutOf`, so Chat's rank survives a shortlist reorder, and "On this trip" shows it as "Chat's #2 of 5". The
history backfill fills them in for existing stops. **Adds synced columns: a CloudKit deploy is owed before TestFlight.**

**Read first:** ADR-0055 (all of it, D7 especially); the archived [`trip-rationale-fields`](archive/trip-rationale-fields.md)
brief, which this extends in the same places; jon-platform `docs/ios/persistence-and-sync.md` § Adding a synced table or
column.

## Today

- `RecommendationHandoffContract.projectInstructions` lists `priority` as "an integer when you can rank it", and its example
  shows `"priority":0`. The seed format doesn't ask for it.
- `TripIdea.commit(candidate:into:in:)` writes `shortlistRank: candidate.priority ?? 0`. `TripIdeaOrdering` and the ring
  helpers in `TripIdea+Alternatives` renumber `shortlistRank` by position, so Chat's number is lost on the first reorder.
- `RecommendationSetImport.commit` and `.apply` have the `HandoffSession`, and so the whole stored candidate set
  (`session.recommendationCandidates()`).
- `TripRationale`, `TripRationaleBackfill`, the "On this trip" section, the per-field merge in `RecommendationEvaluation`,
  and the fill-empty-on-match path in `commit(candidate:)` all come from #231.

## Part 1. Contract

- In `projectInstructions`, replace "priority is an integer when you can rank it" with: "priority ranks this list: 1 is
  your first choice, 2 the next, and so on. Omit it if you can't rank." Change the example's `"priority":0` to
  `"priority":1`.
- Keep `GV-CONTRACT: v2`. Update any test that pins the instructions text.

## Part 2. Schema

- Append a migration that adds two nullable `INTEGER` columns to `tripIdeas`: `rationalePriority` and
  `rationalePriorityOutOf`. Add them to `TripIdea`, its init (`nil` defaults), and `TripRationale` (`priority`,
  `priorityOutOf`). `isEmpty` counts them.
- Update `cloudkit-expected-fields.txt`, with both value fields and both `sqlitedata_icloud_userModificationTime_…`
  fields.
- Carry them wherever #231 carries the other three fields.

## Part 3. Writes

- `outOf` is the number of candidates in the session's stored set with a non-nil `priority`. Compute it in
  `RecommendationSetImport`, and pass it into `commit(candidate:)` as a new `priorityOutOf: Int?` parameter (`nil` when
  the candidate has no priority).
- A new stop gets both fields. `shortlistRank` still starts from `priority`, as today.
- A match fills both when the existing stop's `rationalePriority` is nil, setting them together, never one without the
  other.
- Duplicate merge: keep the existing pair if it's set, otherwise take the duplicate's. Ranks don't concatenate, so this
  isn't `mergedNote`.
- `TripRationaleBackfill.update` also fills the pair when the stop's priority is nil and the candidate has one, with `outOf`
  computed from that session's candidates as above. This must work for a stop whose three text fields are already
  filled, which every row backfilled by #231 is. So split the decision: text fields under the existing rule, and the
  priority pair independently.

## Part 4. Display

- "On this trip" gets a first row, "Chat's pick", with "#2 of 5", or "#2" when `outOf` is nil. Nothing else changes order,
  and nothing sorts by it.
- In the Evaluate candidate card, show the same "#2 of 5" next to Why, Fit and Time, if there's room in its header line.

## Tests

- Migration: the columns exist, and old rows read as nil.
- Import: a set of five with priorities stores `#n of 5`; candidates without a priority store nil for both; reordering the
  shortlist leaves both fields unchanged.
- A match fills an empty pair and leaves a set pair alone. Merge keeps the existing pair.
- Backfill: fills the pair on a stop whose text fields are already filled; a second run does nothing new; a stop with a
  priority already set is left alone.
- Contract text: says 1 is the first choice, and the example shows 1.

## Done when

- `scripts/check-drift.sh` is green, plus the headless app-target run, with its "Test run with N tests" line in the PR.
- `cloudkit-expected-fields.txt` lists the four new fields.
- NEXT_UP's **Owed** line and closeout name the deploy: import `rationalePriority` and `rationalePriorityOutOf` on
  `tripIdeas` with `cktool` and deploy to Production before the TestFlight build. The architect runs the import; Jon
  deploys.
- **Owed by Jon, no code:** re-paste the project instructions (Settings → AI → Copy Project Instructions) into the
  ChatGPT and Claude projects, and restart the Galavant MCP server, whose `chatServerInstructions` embed the same text. Then
  new returns use the new meaning of `priority`.
- Device gate: Erst shows "Chat's pick #3 of …" after the backfill; a new Chat return shows its ranks; reordering the
  shortlist doesn't change them.
