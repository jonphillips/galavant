# Effort — Re-evaluate with Chat: a newer return updates places already on the trip, and Chat's top three wear medals

**Status:** Ready · **Summary:** [ADR-0055](../decisions/0055-trip-rationale-fields.md) D8 and D9. When Chat returns a
place that's already on the trip, its new Visit, Why, Fit and rank replace the old ones. Today they're dropped or stacked
under the old text. A ranked return that repeats places from earlier in the same conversation replaces that
conversation's ranking. The resolve-time Merge / Keep Both dialog goes away. In Considering, on candidate cards and on
alternatives, Chat's top three show gold, silver and bronze medals. Folds in the `rationale-priority-per-return` brief.
No schema change.

**Read first:** ADR-0055 D7–D9; ADR-0037 OQ5 (amended); the superseded
[`rationale-priority-per-return`](archive/rationale-priority-per-return.md) brief, whose Parts 1–2 are this brief's
Part 1. Jon's report, 2026-11-09: he staged Chat's picks, talked with Chat for another 15 minutes, re-ranked, and
restaged. Merge kept the old rank and stacked the old and new reasoning. Keep Both was the only way to keep a rank.

## Today

Three places lose a newer evaluation:

1. **The session store.** `HandoffSession.storeRecommendationCandidates(_:)` calls `RecommendationCandidateSet.merging`.
   A candidate whose `RecommendationCandidateIdentity` (normalized name and locality) is already stored is dropped, so
   a restage in the same conversation never reaches the trip. `outOf` counts the whole stored set (the bug the per-return
   brief fixed).
2. **The commit-time match.** `TripIdea.commit(candidate:into:priorityOutOf:in:)` finds a live trip row by name
   (`liveTripIdea(matching:)`) and only **fills empty** rationale fields. The old text and rank win.
3. **The resolve-time collision.** `ResolveReconcile` asks Merge or Keep Both (`RecommendationWorkspaceView`,
   `UnresolvedRecommendationSheet`). Merge keeps the existing rank (`existing ?? candidate`) and stacks each text field
   (`mergedNote`). Keep Both leaves two live rows for one idea.

Rank shows only as text: "#2 of 5" (`TripRationale.priorityLabel`) in the dossier and as the Why badge on candidate
cards.

## Part 1. The session store records each return and updates repeats (`GalavantSchema`, pure)

`RecommendationCandidateSet.merging(existing:incoming:)` returns
`Merge { candidates, addedCandidates, updatedCandidates, unrankedCandidates }`. Rules, in order:

- **Stamp the return.** This is the per-return brief's Part 1. `TripCandidate` gains `priorityOutOf: Int?`, encoded as
  `galavant_priority_out_of`. It isn't part of the Chat contract. Each incoming candidate gets the count of incoming
  candidates with a non-nil `priority` when it has one, and `nil` otherwise. Anything sent in the JSON is overwritten.
- **A repeat updates in place.** An incoming candidate that matches a stored one replaces the stored candidate's Chat
  fields (name, locality, search hint, why, fit, visit, kind, priority, `priorityOutOf`, day ref, placement, book ahead)
  and **keeps the stored `id`**, so its `candidateLinks` entry still points at its trip row. It's listed in
  `updatedCandidates`. When the incoming return has no priorities at all, the stored `priority` and `priorityOutOf`
  are kept. Only the text updates.
- **A ranked return that repeats a stored place replaces the conversation's ranking.** If the incoming return has at
  least one `priority`, and at least one incoming candidate matched a stored one, every stored candidate with a priority
  that the return doesn't name loses it (`priority` and `priorityOutOf` set to nil). Each of these is listed in
  `unrankedCandidates`. A ranked return that repeats nothing, such as "five more", adds to the session and leaves earlier
  ranks alone, so it gets "#1 of 5" alongside the first list's "#1 of 5".
- New candidates are appended, as today.

`appendRecommendationCandidate` and `replaceRecommendationCandidate` don't change. Add
`HandoffSession.priorityOutOf(for:)`, as the per-return brief's Part 2 described it: the stamp if one is present, and
otherwise the old session-wide count for sessions stored before this change. `RecommendationSetImport.commit` and
`TripRationaleBackfillModel` call it and drop their inline counts.

## Part 2. Updates reach the trip rows (`GalavantSchema`)

- **One rule for a newer evaluation on a row:** add `TripRationale.superseded(by incoming: TripRationale) ->
  TripRationale`, which is pure. Visit, Why and Fit form one unit: if the incoming has any of the three, all three come
  from the incoming, nils included. Priority and `priorityOutOf` form a second unit: if the incoming has a priority,
  both come from the incoming. `note` (`inlineNote`) is never replaced, because it's the stop's own note (ADR-0055 D2).
- **The session's repeats and un-ranks:** add `TripIdea.applyReevaluation(_ merge:, links:, in db:)`. For each updated
  candidate linked to a **live** row (considering, shortlisted or scheduled), it writes the row's rationale from that
  candidate. This is not `superseded(by:)`: the row takes the candidate's rank pair exactly, nil included, because Part 1
  has already decided it. For each un-ranked candidate linked to a live row, it clears `rationalePriority` and
  `rationalePriorityOutOf`. It never touches status, schedule, rings, `shortlistRank`, booking or `inlineNote`.
  Declined and finished rows are left alone.
- **The commit-time match (other conversations, or a place already on the trip some other way):** `TripIdea.commit`
  applies `superseded(by:)` to the matched row in place of the fill-empty update. The `inlineNote` cleanup line and the
  `bookAhead` rule stay as they are.
- **Callers:** the paste flow (`pasteRecommendationResult`) runs `applyReevaluation` in a `database.write` right after
  it stores the session. The chat inbox (`RecommendationSetImport.apply`) runs it in its own transaction, before it
  commits the new candidates. Seed import ignores the two new lists: seeds carry no rank, and their notes go to
  `inlineNote`.
- **Why this doesn't break the pull rule (ADR-0004):** the paste is Jon's gesture, and these writes change Chat's notes
  on places that are already on the trip. They never add a place.

## Part 3. Resolve folds without asking (`GalavantSchema` and app target)

- `ResolveReconcile` drops `Choice` and `keepBoth`. A collision always folds: the existing row keeps its placement, its
  rationale becomes `existing.superseded(by: resolving)`, `inlineNote` merges the way it does today (`mergedNote`), and
  the duplicate row is removed. The row being resolved counts as the newer evaluation, since resolving is the later
  gesture. (The rare older-candidate case is accepted.)
- Remove the dialog from `RecommendationWorkspaceView` and `UnresolvedRecommendationSheet`, along with the model's
  pending-choice state. Show **"Already on this trip — updated Chat's notes."** on the surface's existing message line.
- Going to the same place twice stays `repeatScheduled`, a separate gesture. Keep Both isn't how you do that.

## Part 4. Say what happened (app target)

The paste summary replaces "N new, M already on this trip" with the clauses that apply, in this order, leaving out any
that are zero: **"3 new · 4 updated · 2 no longer ranked"**. When all are zero: **"Nothing new."** The counts are Part
1's three lists.

## Part 5. The contract says how to re-rank

In `RecommendationHandoffContractInstructions`, after "Omit it if you can't rank.", add: **"To revise a ranking, return
every place you still recommend in it, ranked together. When a ranked return repeats a place from earlier in this
conversation, Galavant replaces the earlier ranking, and places you leave out lose their rank."** The marker stays
`GV-CONTRACT: v2`, as it did for D7, because this clarifies an existing field. Jon re-pastes the project instructions
(that's in the gate).

## Part 6. Medals (app target)

- A `RankMedal` view in `Galavant/Design`, taking `priority` and `priorityOutOf`. Priority 1, 2 or 3 draws a small disc
  with the numeral, tinted gold, silver or bronze, legible in light and dark. The numeral means it never relies on color
  alone. Its accessibility label is **"Chat's first choice of 5"** ("second", "third"), dropping "of N" when
  `priorityOutOf` is nil. It draws nothing for priority 4 and up, for no priority, or when `priorityOutOf == 1`, since a
  one-place return has nothing to beat.
- **Where:** next to the title in Considering rows (`TripIdeasView`, through a new optional `PlanningRow` parameter),
  in an alternatives group's options (`AlternativeSlotDisclosure` and the ring rows), and in the candidate card header
  in Evaluate (`RecommendationCandidateCardPresentation`; the "#2 of 5" Why badge stays).
- **Not:** Shortlist, the itinerary, To Be Scheduled, or map pins. There the decision is made, or the order is Jon's own.
  The dossier keeps "Chat's pick #2 of 5".
- Medals don't sort anything. Considering keeps its order.

## Tests

- **Merging:** two ranked returns of 5 with no overlap: every candidate is stamped 5, and nothing is un-ranked. A
  re-ranking return repeats 3 of 5, drops 2 and adds 1: the 3 take the new text, rank and stamp (4) and keep their
  ids; the 2 are un-ranked; the 1 is added. An unranked return repeating a ranked place: the text updates and the rank
  is kept. A return with 3 ranked and 2 unranked: 3 and nil. A sent `galavant_priority_out_of` is overwritten. The
  payload round-trips, and an unstamped payload decodes as nil.
- **`priorityOutOf(for:)`:** uses the stamp when it's there, and the session-wide count when it isn't.
- **`superseded(by:)`:** incoming text replaces all three (nils included); no incoming text keeps the existing text;
  an incoming rank replaces the pair; no incoming rank keeps it; the note is never touched.
- **`applyReevaluation`:** an updated linked row that's scheduled on day 3 in a ring keeps its status, day, ring and
  `shortlistRank`, and takes the new rationale. An un-ranked row loses only the pair. A declined linked row is
  unchanged.
- **Commit-time match:** an existing row with old text and "#2 of 5" takes a new return's text and "#1 of 4".
- **Resolve:** a collision folds with no choice. The existing row keeps its placement and takes the resolving row's
  rationale. Both `inlineNote`s survive, and one row remains.
- **Import, end to end:** stage 5 ranked, then re-rank 4 under the same token. The trip rows show the new labels, and
  the dropped places show none.
- **Medal:** a pure helper for the medal tier and the label: 1, 2 and 3 → gold, silver, bronze; 4 → none; outOf 1 →
  none; nil outOf → "Chat's first choice".

## Out of scope

- Fixing rows already stored, including the duplicate rows left by earlier Keep Both choices. Jon removes those by hand.
- Saying which list a medal came from. The trip row doesn't store that, and a session is local to one device.
- Sorting Considering by rank, and Jon's own stars.
- Merging two rows that already exist outside of resolve.

## Done when

- `scripts/check-drift.sh` is green, plus the headless app-target run, with its "Test run with N tests" line in the PR.
- The closeout carries this gate, word for word, with `--gate`:

  > **Re-evaluate with Chat (`chat-reevaluation`).** First re-paste Galavant's project instructions into ChatGPT. On the
  > iPad, TestFlight build. In one Chat conversation, ask for five ranked places for a trip and import them. Gold,
  > silver and bronze show on the top three in Considering. Then ask Chat to re-rank: drop two, add one, and change the
  > order. Paste it: the summary says "1 new · 3 updated · 2 no longer ranked". The medals follow the new order, the
  > dossier's Why is the new text, and the two dropped places have no medal. Use This Place on a candidate that's
  > already shortlisted: no Merge / Keep Both question, one row, and the notice. On the iPhone, the same medals show in
  > Considering. **Then judge:** Did the re-rank do what you meant? Are the medals on the right rows, and the right
  > size? Do you miss the old text when it's replaced?
