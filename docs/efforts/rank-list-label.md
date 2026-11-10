# Effort — Name Chat's ranked lists: "① Soho Indian", "② Manchester hotels"

**Status:** Ready · **Summary:** [ADR-0055](../decisions/0055-trip-rationale-fields.md) D10. The contract asks Chat to name
each ranked return in a new optional `list` field. `TripIdea` gains `rationalePriorityList`, which is written and cleared
together with the rank. The medal moves to the row's last line and is followed by the list's name, on trip rows, in the
guide, in candidate cards and in the dossier. **Adds a synced column: a CloudKit deploy is owed before TestFlight.**
Queued behind [`guide-deliberation`](archive/guide-deliberation.md), whose `ChatRank` value it extends.

**Read first:** ADR-0055 D7–D11; the archived [`trip-rationale-priority`](archive/trip-rationale-priority.md) and
[`chat-reevaluation`](archive/chat-reevaluation.md) briefs, which this follows step for step; jon-platform
`docs/ios/persistence-and-sync.md` § Adding a synced table or column.

## Today

- `TripCandidate` decodes `priority`; import adds `priorityOutOf` per return. `TripIdea.rationalePriority` /
  `rationalePriorityOutOf` carry them. `TripRationale` holds `priority` / `priorityOutOf`.
- The pair is written or cleared in `RecommendationHandoff.commit(candidate:…)`, in `RecommendationCandidateMatching`
  (D8's re-rank, including clearing places a re-rank leaves out), in `RecommendationEvaluation`'s merge, in
  `TripIdea`'s duplicate merge (around `TripIdea.swift:325`) and in `TripRationaleBackfillModel`. Grep
  `rationalePriority`: every hit is a place the third column has to go.
- After `guide-deliberation`, `ChatRank` (`priority`, `priorityOutOf`) feeds the guide's medals. `PlanningRow` draws
  `RankMedal` beside the title, and the candidate cards draw it in their header.

## Part 1. Contract

- In `projectInstructions`, add `list` to the candidate field list, and say: "When you rank, also give list: the same
  two-to-four-word name, on every ranked place in this return, for what the ranking answers (for example "Soho Indian"
  or "Manchester hotels"). When you revise a ranking, keep its name unless the question changed." Add `"list":"…"` to the
  example.
- `TripCandidate` decodes `list` (trimmed, empty becomes nil, capped at 40 characters). Check the seed format and
  `stage_trip_return` (GalavantMCP) both reach the same decoder. If either has its own field list, add `list` there too.
- Keep `GV-CONTRACT: v2`. Update tests that pin the instructions text.

## Part 2. Schema

- Append a migration that adds one nullable `TEXT` column, `rationalePriorityList`, to `tripIdeas`. Add it to `TripIdea`
  and its init (default `nil`), to `TripRationale` (`priorityList`), and to `ChatRank` (`list`).
- Update `cloudkit-expected-fields.txt` with the value field and its `sqlitedata_icloud_userModificationTime_…` field.

## Part 3. Writes

- The three fields move together. Wherever the pair is written, the name is written. Wherever the pair is cleared, the
  name is cleared. A stop never has a name without a rank.
- At import, the name is the return's `list`. If the candidates in one return disagree, take the most common non-nil
  value. If none has one, the fallback is the handoff session's scope: `.day(n)` gives "Day n", and every other scope
  gives nil. `RecommendationHandoffScope(sourceType:scopeKey:)` decodes it. A return with no session gets no fallback.
- D8's re-rank replaces the name along with the rank, so a renamed list renames every place in it.
- Merge and backfill keep the three together. Prefer the existing triple if its rank is set, otherwise take the other
  one, never mixing parts of two triples. The backfill gives a name only where the stored candidate set has one. Ranks
  kept before D10 stay unnamed.

## Part 4. Display

- `PlanningRow`: the medal leaves the title line. On the subtitle line, after the kind ("Food"), draw the medal and then
  the list name: "Food · ① Soho Indian". The name is `.subheadline`, secondary, one line, and it truncates before the
  medal does. With no subtitle, the medal and name make up the line by themselves. With no name, the medal sits there
  alone. The VoiceOver label adds the name: "Chat's first choice, Soho Indian".
- The guide card (from `guide-deliberation`): the medal is followed by the name, on the badge line after "On trip".
- The candidate cards in Evaluate: the name follows the medal where it sits now.
- The dossier's "On this trip": "Chat's pick #2 of 5 · Soho Indian".
- Medals still appear only where D9 and D11 put them, and nothing sorts by rank or name.

## Tests

- Migration: the column exists, and old rows read it as nil.
- Decode: `list` is trimmed and capped, and an empty one is nil. A return whose candidates disagree takes the most common
  name. A day-scoped return without `list` gets "Day 3". A trip-scoped one gets nil.
- Re-rank: a renamed re-return renames every ranked place. A place it leaves out loses its rank and its name together.
- Merge and backfill: the three fields never mix between two stops. A stop never ends up with a name but no rank.
- Contract text names `list` and shows it in the example.

## Done when

- `scripts/check-drift.sh` is green, plus the headless app-target run, with its "Test run with N tests" line in the PR.
- `cloudkit-expected-fields.txt` lists the new field.
- NEXT_UP's **Owed** line and closeout name the deploy: import `rationalePriorityList` on `tripIdeas` with `cktool` and
  deploy to Production before the TestFlight build. The architect runs the import, and Jon deploys.
- **Owed by Jon, no code:** re-paste the project instructions (Settings → AI → Copy Project Instructions) into the ChatGPT
  and Claude projects, and restart the Galavant MCP server.
- Device gate (iPad, TestFlight build): in one Chat conversation, ask for five ranked Soho Indian restaurants and import
  them. Considering shows "Food · ① Soho Indian" and so on. Ask the same conversation for ranked Manchester hotels. Each
  list keeps its own name and its own gold. With the London guide's lens on the trip, the cards show the same names. Then
  judge: Does Chat's name for each list read the way you'd say it? Does the last line still scan?
