# Effort — Evaluate duplicate candidate sets

**Status:** Dispatched (2026-09-29) · **Summary:** re-pasting a recommendation result (or a new handoff
session) duplicates candidates and orphans resolved rows; merge on re-paste, link on commit, and say
what happened. Found in the 2026-09-28 dogfood round (item 2). Implements ADR-0036/0037 behavior.

## Diagnosis (moved from `CURRENT_HANDOFF.md`)

**Evaluate matches "reverting" (item 2): diagnosed as duplicate candidate sets, fix
  not built.** Jon pasted a recommendation result twice. `TripCandidate` decoding mints a
  fresh UUID per candidate on every paste, and
  `HandoffSession.storeRecommendationCandidates` rebuilds `candidateLinks` from the new
  set only. So a re-paste silently drops the links to already-committed (and resolved)
  rows, and committing the re-pasted set creates duplicate freeform `.considering` rows.
  A new handoff session produces the same duplicates across sessions. Evaluate then shows
  the grey duplicates, while the resolved originals sit orphaned on the trip. Fix:
  (a) re-paste merges into the existing set, keeping candidates and links and appending
  only unmatched candidates (normalized name + locality); (b) commit checks the trip for a
  live row with the same normalized title and links to it instead of inserting;
  (c) the paste shows feedback ("N new, M already on this trip"). Recovery needs no code:
  rematching a grey duplicate to the same place raises the `ResolveReconcile` collision,
  and choosing **Merge** folds it into the original.

## Done when

- (a) Re-pasting into an existing set merges: existing candidates and their `candidateLinks` are kept,
  and only unmatched candidates (normalized name + locality) are appended.
- (b) Committing a candidate links to a live row on the trip with the same normalized title instead of
  inserting a duplicate `.considering` row. This holds across handoff sessions, too.
- (c) The paste reports what happened ("N new, M already on this trip").
- Pure matching and merge logic lives in the package with tests covering re-paste, a cross-session
  duplicate, and an already-resolved original. No recovery migration: existing duplicates are
  merged by hand through the `ResolveReconcile` **Merge** path.
