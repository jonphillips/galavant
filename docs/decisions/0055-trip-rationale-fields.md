# ADR-0055: Chat's visit, why and fit are kept as three fields on the trip stop

*Status: **proposed** — 2026-11-08, ratified by Jon merging this ADR's PR. Effort:
[`trip-rationale-fields`](../efforts/archive/trip-rationale-fields.md). Amends [ADR-0036](0036-recommendation-handoff.md) D3 (the
rationale note). Reads into the dossier from [ADR-0053](0053-taste-record-and-region-guide.md).*

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

**D6. Duplicate merges handle each field the way `inlineNote` is merged today** (`RecommendationEvaluation.mergedNote`).

## Consequences

- **Owed before TestFlight:** import the three fields with `cktool` and deploy the schema to Production, as for any added
  synced column. The same PR updates `cloudkit-expected-fields.txt`.
- The migration is appended as a new registration. Registered migrations stay frozen.
- Recommendation cards in Evaluate already show Why, Fit and Time. They now match what's saved.
