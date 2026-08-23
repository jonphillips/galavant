# Codex task: include the current stops in the recommendation handoff brief

## Problem

The ADR-0036 recommendation handoff (export a brief → paste into ChatGPT/Claude →
round-trip candidate places back) exports a brief that gives the external LLM
almost nothing about the trip. A real handoff came out as just:

```
GV-HANDOFF: F96B8165-7C82-4F2A-8346-6A77EBC98DBF
Trip: Bavaria/Dolemites
Ask: Recommend candidate places that fit this trip. Give options with a useful
locality, search hint, and concise rationale.
```

No stops, no itinerary — so the model is recommending places for a trip it knows
nothing about beyond the name. (The `Trip notes:` line only appears when the trip
has notes; this trip has none.)

This is not a regression. `RecommendationHandoffContract.brief` never rendered the
itinerary — it only ever emits the header, trip name, optional trip notes, and the
ask. The stop context was simply never wired in.

## Goal

Fold a **compact stop list** into the brief: one line per current stop — title +
locality — grouped by day. Enough that the model avoids re-suggesting covered
ground and can fit gaps, without a giant paste.

## Where

- Rendering: `GalavantLibrary/Sources/GalavantSchema/RecommendationHandoff.swift`
  — `RecommendationHandoffContract.brief(...)` (around line 71). Keep this **pure
  and in `GalavantSchema`** so it stays testable next to the existing
  `GalavantLibrary/Tests/GalavantSchemaTests/RecommendationHandoffTests.swift`.
- Caller: `Galavant/Trips/TripPlanningModel+Recommendation.swift` —
  `startRecommendationHandoff()` (around line 66–88). It already has `model.plan`
  (a `TripPlan`) available, which is where the resolved stops live.

## Design / shape

`TripPlan` (also in `GalavantSchema`) is the source of the stop data. Its
projections you want:

- `plan.itinerary` → `[ResolvedDay]` (day `number` + ordered `stops`)
- `plan.toBeScheduled` → `[ResolvedStop]` (scheduled-but-unplaced bucket)
- `plan.stays` → `[ResolvedStay]` (home bases, ADR-0011) — carry the locality anchor

Each `ResolvedStop.content` is a `StopContent`:
- `.idea(Idea)` → title = `content.title`; **locality** = the idea's `regionName`
  (fall back to `address` only if you want, but `regionName` is the intended field).
- `.freeform(title, note, coordinate)` → title only, no locality.
- `.stay(...)` → title only.

Recommended approach:

1. Add a small **pure helper** in `RecommendationHandoff.swift` that turns a
   `TripPlan` into the compact stop-summary lines — e.g.
   `RecommendationHandoffContract.stopSummary(plan: TripPlan) -> [String]` (or a
   nested value type). Grouping: `Day N:` header, then `- <title> (<locality>)`
   per stop; omit the ` (<locality>)` when there's no locality. Include a
   `To be scheduled:` group for `toBeScheduled` if non-empty, and optionally a
   `Staying:` line per stay. Skip empty days. If there are no stops at all, render
   nothing extra (don't emit an empty "Stops:" header).
2. Extend `brief(...)` to take the plan (or the pre-rendered lines) and insert a
   `Stops so far:` section between the trip line/notes and the `Ask:` line. Decide
   the signature: passing the `TripPlan` keeps the caller trivial and the render
   fully testable; passing pre-rendered `[String]` is also fine — your call, but
   keep the rendering pure and unit-tested.
3. Update `startRecommendationHandoff()` to pass `plan` (via
   `RecommendationHandoffScope.trip` is unchanged) so the brief carries the stops.

Keep it "current stops" = scheduled itinerary + to-be-scheduled + stays. Do **not**
include `shortlist` or `considering` — those aren't committed to the plan and would
muddy "what's already on the trip." (If you think one belongs, note it in the PR
rather than silently adding it.)

## Tests

Add cases to `RecommendationHandoffTests.swift` (build a `TripPlan` from arrays the
way `RecommendationWorkspaceProjectionTests`/`JourneyProjectionTests` already do):

- A multi-day trip renders `Day 1:`/`Day 2:` groups with `- Title (Region)` lines,
  in itinerary order.
- A stop whose idea has no `regionName` renders `- Title` with no parens.
- A freeform stop renders title-only.
- An empty trip (no stops, no stays) renders the same three-line brief as today
  (no stray "Stops so far:" header) — guard the existing minimal-brief behavior.
- Trip notes still render when present, and the stops section sits between notes
  and the `Ask:` line.

## Constraints / conventions

- Follow the repo's AGENTS.md house style (value types, pure core, no fat model
  logic — the render stays in `GalavantSchema`, not the `@Observable` model).
- No new files/targets needed, so no `project.yml` / XcodeGen changes. If you do
  add a file to a package target, it's picked up by SPM automatically; only the
  app target needs `project.yml` edits.
- `swift test` aborts in this environment for FoundationModels-linked bundles, but
  the `GalavantSchemaTests` target is the pure core — run those. If the schema test
  target won't run standalone here, at minimum make the app build clean.
- Land via a feature branch + PR to `main` (never push to `main` directly). Keep
  the PR focused on this brief change.

## Acceptance

The Bavaria/Dolemites handoff, with its current itinerary, exports a brief that
lists its stops grouped by day (title + locality) between the trip line and the
ask, and the empty-trip case is unchanged.
