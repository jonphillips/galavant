# ADR-0055: Chat's visit, why and fit are kept as three fields on the trip stop

*Status: **proposed** — 2026-11-08, ratified by Jon merging this ADR's PR. Effort:
[`trip-rationale-fields`](../efforts/archive/trip-rationale-fields.md). Amends [ADR-0036](0036-recommendation-handoff.md) D3 (the
rationale note). Reads into the dossier from [ADR-0053](0053-taste-record-and-region-guide.md).*

*Amended 2026-11-08: **D7** keeps Chat's `priority` too, after Jon noticed it was missing from the dossier. Effort:
[`trip-rationale-priority`](../efforts/archive/trip-rationale-priority.md).
Its brief counted "of N" across the whole session, not per return;
[`rationale-priority-per-return`](../efforts/archive/rationale-priority-per-return.md) corrected it, and
[`chat-reevaluation`](../efforts/archive/chat-reevaluation.md) folds that fix in.*

*Amended 2026-11-09: **D8** makes a newer return from Chat replace its earlier evaluation of a place on the trip, and
**D9** gives Chat's top three medals. This came from Jon re-ranking with Chat and restaging. Effort:
[`chat-reevaluation`](../efforts/archive/chat-reevaluation.md), which folds in the per-return fix. D8 replaces D6 for the
rationale fields.*

Summary: When Chat recommends a place, its `visit`, `why` and `fit` are kept as three labeled fields on the trip stop
(`TripIdea`), not packed into one note. The dossier shows them as "On this trip" wherever it knows the trip, including the
guide, above Taste Notes. Taste Notes move to the bottom of the dossier until the place has been visited, then to the top.
This is an additive, synced schema change, so a CloudKit deploy comes before the TestFlight build.

## Context

The hand-off contract asks Chat for `why`, `fit` and `visit`, and says all three are about *this* trip
(`RecommendationHandoffContractInstructions`). `place_notes` are the facts that hold on any visit. What Galavant keeps
today:

- **Candidate import** (`TripIdea.commit(candidate:)`, the path for Evaluate, the MCP inbox and pasted returns) writes
  `inlineNote = why + "\n\n" + fit` and **drops `visit`**.
- **Seed import** (`SeedPlan`) packs why, fit, visit, the verdict reason and place notes into `inlineNote`.
- The originals survive only in this device's `HandoffSession` history (`candidatePayload` plus `candidateLinks`), which
  doesn't sync.
- The trip detail shows `inlineNote` as "Why it's on this trip". The guide's dossier shows none of it.

Jon, looking at Erst in Manchester from the guide (2026-11-08), needs all three, labeled, before Taste Notes.

## Decision

**D1. `TripIdea` gains three nullable synced text columns: `rationaleVisit`, `rationaleWhy`, `rationaleFit`.** They go on
the trip stop, not on `Idea`, because the contract scopes them to the trip. A second trip to Manchester gets its own.

**D2. `inlineNote` stays the stop's free-form trip note.** Import stops packing `why`, `fit` and `visit` into it. Seed
import still puts the verdict reason, the deferral line and place notes there. This amends ADR-0036 D3: the AI's rationale
is now these three fields. Resolution still never touches them. Attaching a resolved idea stays a one-column write.

**D3. The dossier shows "On this trip" whenever it has a trip.** Visit, Why and Fit, each labeled, in that order, then the
note. This comes before Taste Notes and accolades. It applies to the trip detail, and to the guide when its lens has a
trip.

**D4. Taste Notes sit at the bottom until the place has been visited, then at the top.** A place counts as visited when
`Idea.visited` is set, or when one of its stops has `completedAt` set, or when it's a scheduled, unskipped stop on a dated
trip whose day is before today. This replaces `Emphasis.forKind`, which put notes first for stays. One consequence: a
hotel with notes but no visit now shows its notes at the bottom.

**D5. Existing rows are backfilled where possible.** The backfill is best effort, local to the device, and safe to rerun.
For each handoff-session link that points at a stop: if the stop's three fields are empty and its `inlineNote` exactly
equals what the old import wrote from that candidate, write the three fields and clear the note. Any other row is left
alone. The backfill runs on the device that holds the history (Jon's), and the result syncs to Wendy.

**D6. Duplicate merges handle each field the way `inlineNote` is merged today** (`RecommendationEvaluation.mergedNote`). *Superseded by D8 for Visit, Why, Fit and rank; `inlineNote` still merges this way.*

**D7. Chat's `priority` is kept too, as a rank within its list** (amendment, 2026-11-08). Today import copies
`priority` into `shortlistRank`. That's an ordering key: it's renumbered whenever the shortlist or a ring is reordered, it's
never shown, and the contract never said which way it points. So:

- The contract says it: `priority` is 1 for Chat's first choice, 2 for the next, and so on, ranked within this one list.
  The version marker stays `GV-CONTRACT: v2`, since this clarifies a field that's already there. Jon re-pastes the project
  instructions into ChatGPT and Claude.
- `TripIdea` gains two nullable synced integer columns: `rationalePriority`, and `rationalePriorityOutOf`, the number of
  candidates in that return that carried a priority. A rank only means something within its own list, so the dossier
  shows it as "Chat's #2 of 5", and nothing sorts across lists by it. `shortlistRank` still takes its starting order from
  `priority`, but reordering no longer erases Chat's rank.
- Merges and the history backfill treat these two like the other rationale fields. Ranks from returns made before the
  contract fix may point either way. The backfill keeps them anyway, because the dossier shows the number and doesn't act
  on it.
- Seed returns don't send `priority`, and that's unchanged.

**D8. A newer return from Chat replaces its earlier evaluation** (amendment, 2026-11-09). Going back to Chat and
re-ranking is normal use, and the newer opinion is the one Jon wants. Stacking the old and new text, and keeping the
first rank (D6, ADR-0037 OQ5), hid the update.

- When a return names a place that's already on the trip, its Visit, Why and Fit replace the old ones as a unit, and
  its rank replaces the old rank when it carries one. Placement never changes: status, day, ring and order stay Jon's.
  So does the stop's own note (D2).
- Within one Chat conversation (one handoff session), a ranked return that repeats an earlier place is the current
  ranking. Places it leaves out lose their rank. A ranked return that repeats nothing ("five more") adds a list
  alongside the first. Across conversations, ranks are never cleared, because each conversation ranks its own list.
  The contract text says this, so Chat knows to return the whole revised list.
- Each rank's "of N" counts its own return (D7 as written; the per-session count was a bug).
- Resolving a candidate onto a place already on the trip folds into the existing row without asking. That amends
  ADR-0037 OQ5: Keep Both is retired. Going to a place twice is `repeatScheduled`.
- The paste that brings the newer return is Jon's gesture, and it only changes Chat's notes on places that are already
  on the trip. ADR-0004's pull rule holds.
- No schema change. These are D1 and D7's columns, overwritten.

**D9. Chat's top three wear medals where the choice is still open** (amendment, 2026-11-09). Gold, silver and bronze,
with the numeral, on Considering rows, alternatives options and candidate cards. There are no medals on the shortlist,
the itinerary or the map, because there the decision is Jon's. A one-place return earns no medal. Medals don't sort.
Two lists in one conversation can each have a gold. That's honest, because each was its own ranking.

## Consequences

- **Owed before TestFlight:** import the three fields with `cktool` and deploy the schema to Production, as for any added
  synced column. The same PR updates `cloudkit-expected-fields.txt`.
- The migration is appended as a new registration. Registered migrations stay frozen.
- Recommendation cards in Evaluate already show Why, Fit and Time. They now match what's saved.
- D7 adds two more synced columns, so the same `cktool` import and Production deploy are owed for that slice.
