# Effort — Keep what Chat said around its places; Find on Map from Ruled out

**Status:** Queued (2026-10-30), behind `sync-failure-surfacing` · **Summary:** two small follow-ups
from the ADR-0048 trip-seed work. (1) A pasted recommendation return keeps only the first JSON array of
places. Any text around it, including a `summary` field when Chat wraps the array in an object, is
dropped without a word. The review now shows that text and can save it to the trip's documents. (2)
A ruled-out row with no place behind it can't be found on the map, so a deferred place never reaches the
pool. Ruled out rows gain **Find on Map**. No schema, migration, sync or contract change.

From `docs/open-questions.md` § Trip seed handoff (both entries). ADR-0048 Slice 0 run 1 is the case for
(1): the `summary` was the only place the deferred northern-trip places appeared.

## Today

- `TripCandidate.decodeReturn(_:)` (`GalavantSchema/RecommendationHandoff.swift`) slices the first
  `[{…}]` array with `jsonArraySlice(in:)` and decodes only that. Its one caller is
  `TripPlanningModel+Recommendation.swift` (the paste handler), which shows a warning line
  (`recommendationHandoffWarning`) in `RecommendationHandoffSheet` above the review.
- The seed path (`SeedReturn.decode`) already keeps its narrative as the founding `TripDocument`. Leave
  it alone.
- `TripIdeasView`'s **Ruled out** disclosure lists `plan.ruledOut` with one context-menu action,
  **Reconsider**. `UnresolvedRecommendationSheet` (presented from `TripDetailContent` as
  `destination.recommendationDetail`) has **Find on Map**, which calls
  `recommendationPlaceSelected(stopID:place:)` → `RecommendationResolution.confirm` →
  `TripIdea.attachResolvedIdea`.

## 1. The review shows what Chat said around the places

- **Pure, in `GalavantSchema`:** `decodeReturn` returns a value carrying the candidates **and** a
  `note: String?`, the reply's text that isn't the candidate array. Keep the existing error cases.
  - If the reply (after the routing token and contract marker are stripped, curly quotes normalized, and
    a surrounding code fence removed) parses as a JSON **object** that holds the candidate array, the
    note is that object's other top-level string values, each as `key: value` on its own line, in key
    order. A nested non-string value is skipped, not dumped.
  - Otherwise the note is the text before and after the array, trimmed, with code-fence lines removed.
  - `nil` when nothing is left. Never return JSON punctuation fragments (`{"summary": …, "places":`).
- **App:** the paste handler keeps the note on the model next to the warning. `RecommendationHandoffSheet`
  shows it above the candidates as **Chat also said**, selectable, with a **Save to Trip Documents**
  button. Saving inserts a `TripDocument` with `origin: .pasted`, the title "Chat notes — <date>", and the
  note as its body, through the existing `add` in `TripDocumentOperations.swift`. The button saves once, then
  reads "Saved". The note isn't stored anywhere else and goes away when the sheet closes.
- Re-pasting replaces the note with the new reply's.

## 2. Ruled out → Find on Map

- In the **Ruled out** disclosure, a row whose stop has no idea (an unresolved recommendation) gains
  **Find on Map** in its context menu, next to **Reconsider**. It sets `destination.recommendationDetail`
  to the stop, the sheet `UnresolvedRecommendationSheet` already uses. Present it through
  `TripDetailContent` as today: trip sheets must not be hosted outside it (KNOWN-ISSUES, iPhone).
- Resolving a ruled-out stop **keeps it ruled out**: status stays `.declined` and its reason is kept. The
  place joins the pool as an idea. Check that `RecommendationResolution.confirm` and
  `attachResolvedIdea` leave status and reason alone; if either resets them, fix it there and test it.
- The "Already on your trip" collision path works as it does from the Evaluate queue.
- A row that already has an idea gets no new action.

## Tests

**Library** (`GalavantLibrary`):
1. `decodeReturn`, with fixtures: a bare array (no note); prose before and after (note is the prose); a
   fenced array with prose (fence lines gone); an object with `summary` and `places` (note is
   `summary: …`); an object with a nested non-string field (skipped). Every existing decode test still
   passes: update its expected type, not its expectations.
2. Resolving a `.declined` unresolved stop keeps `.declined` and the reason, and creates the pool idea.

**App** (`GalavantTests`): saving the note writes one `TripDocument` with `origin == .pasted`, and a second
tap doesn't write another.

## Done when

- One PR on branch `effort/seed-handoff-cleanups`. `scripts/check-drift.sh` is green and headless
  `GalavantTests` pass.
- No schema, migration, sync-contract or identifier change.
- The completing PR:
  - adds a DONE-LOG entry and marks this brief Done in `docs/efforts/README.md`;
  - removes both entries from `docs/open-questions.md` § Trip seed handoff;
  - adds to `docs/device-passes.md` under **Verification gates**: *paste a recommendation reply that wraps
    its places in `{"summary": …, "places": […]}`: the review shows "Chat also said" with the summary;
    Save to Trip Documents, and the document appears on the other device. In Ruled out, Find on Map on an
    unresolved row: the place joins the Ideas pool and the row stays ruled out;*
  - sets `docs/NEXT_UP.md` to exactly this block:

    ```
    # Next Up — Visited roll-up: a finished trip marks its places visited

    **Slices:** effort `visited-rollup` (one PR, branch `effort/visited-rollup`)
    **Briefs:** `docs/efforts/visited-rollup.md`
    **Done when:** per the brief's "Done when"; verification per `docs/verification.md`.
    **Owed:** carry over the current **Owed:** line unchanged. This effort adds a synced column, so
    the architect escalates the PR to Jon, and the Production schema deploy comes before the next
    TestFlight build.
    **Notes:** ADR-0004 and ADR-0039 §1. The roll-up flips `Idea.visited` only; stop status and the
    live check-off overlay are untouched. Start from a fresh `main`.
    ```
