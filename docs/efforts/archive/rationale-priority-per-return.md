# Effort — Chat's rank counts against its own return

**Status:** Superseded by [`chat-reevaluation`](../chat-reevaluation.md), 2026-11-09, which folds in Parts 1–2 · **Summary:** [ADR-0055](../../decisions/0055-trip-rationale-fields.md) D7, corrected. A rank's "of N"
counts the candidates in the return it came in, not every candidate stored in its handoff session. Today a second return
pasted under the same `GV-HANDOFF` token labels its top pick "#1 of 10". Each candidate now records its return's count
when the return is stored. No schema change and no CloudKit work: sessions are local.

**Read first:** ADR-0055 D7 ("the number of candidates in that return that carried a priority"); the archived
[`trip-rationale-priority`](trip-rationale-priority.md) brief, whose Part 3 defined `outOf` wrongly (the
architect's error, caught in the #239 review).

## Today

- `RecommendationSetImport.commit` sets `outOf` to the number of candidates in the **whole stored set** with a non-nil
  `priority`. `TripRationaleBackfillModel` does the same per session.
- A return reaches the stored set only through `HandoffSession.storeRecommendationCandidates(_:)`
  (`RecommendationHandoff.swift`), from three callers: the paste flow (`TripPlanningModel+Recommendation`), the chat
  inbox (`RecommendationSetImport.apply`), and seed import (`SeedPlan.commitPlaces`). It calls
  `RecommendationCandidateSet.merging`, which returns `existing + addedCandidates`. So a "five more" follow-up under
  the same token grows the set from 5 to 10, and its picks get "of 10".
- The stored set is `candidatePayload`, JSON-encoded `[TripCandidate]` on a `HandoffSession`. `HandoffSessionStore`
  keeps sessions in `UserDefaults` (LLMHandoffKit), so the payload is local and never synced. Adding a key to it isn't a
  schema change.
- The candidate card and "On this trip" both read the stop's stored pair (`tripIdea.rationale.priorityLabel`), so fixing
  the write fixes both.

## Part 1. Record the return's count on each candidate

- `TripCandidate` gains `priorityOutOf: Int?`. It's Galavant's own bookkeeping, not part of the Chat contract. Encode
  and decode it under the key `galavant_priority_out_of`, so it round-trips through `candidatePayload`. Don't add it to
  `projectInstructions`, and don't touch `GV-CONTRACT`.
- In `storeRecommendationCandidates(_:)`, before merging, count the incoming candidates with a non-nil `priority`. Set
  `priorityOutOf` on each incoming candidate: that count when the candidate has a priority, `nil` otherwise. This
  overwrites anything that arrived in the JSON, so Chat can't set it. Count the **whole incoming return**, not only
  `addedCandidates`: the return's size is what Chat ranked against, even if some of its places were already stored.
- `appendRecommendationCandidate` (manual add) and `replaceRecommendationCandidate` stay as they are. A manual candidate
  has no priority. A replaced candidate carries its stored value through, because the caller passes a candidate it read
  from the set.

## Part 2. Read it in one place

- Add `HandoffSession.priorityOutOf(for candidate: TripCandidate) throws -> Int?`:
  - `nil` when `candidate.priority` is nil;
  - otherwise `candidate.priorityOutOf`, if set;
  - otherwise the old session-wide count, for sessions stored before this change. Their payload doesn't record where one
    return ended and the next began, so the session-wide count is still the best they have.
- `RecommendationSetImport.commit` and `TripRationaleBackfillModel` both call it, and drop their inline counts. The
  backfill passes it per candidate, not one count per session.

## Not in scope

- **Correcting pairs already stored.** A match and the backfill only fill an empty pair (D7), and older sessions can't
  be fixed anyway. The only rows affected are stops imported from a second return in the same session since #239 shipped
  (2026-11-09). Leave them.
- Any change to the contract text, sorting, or display.

## Tests

- Storing a ranked return of 5, then a second ranked return of 5 under the same session: every candidate from the first
  has `priorityOutOf == 5`, and so does every **new** candidate from the second. A candidate that repeats a stored one
  keeps its first stamp.
- A return with 3 ranked and 2 unranked candidates: the ranked ones get 3, and the unranked ones get `nil`.
- A `priorityOutOf` sent in the incoming JSON is overwritten.
- The payload round-trips: encode, then decode, and the stamp survives. A payload with no stamp still decodes, as `nil`.
- `priorityOutOf(for:)`: uses the stamp when it's present, and falls back to the session-wide count when it isn't.
- Import, end to end: two returns of 5 under one token produce stops labeled "#1 of 5" from both, never "of 10".
- Backfill: a legacy session (no stamps) still fills the session-wide count; a stamped session fills each candidate's
  own.

## Done when

- `scripts/check-drift.sh` is green, plus the headless app-target run, with its "Test run with N tests" line in the PR.
- No device gate: nothing changes on screen except the number after "of", and only for a second return in a session.
  Tests cover it.
