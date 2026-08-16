# ADR-0039: Today becomes an execution surface — stop completion, skip, and defer as reversible overlays on `TripPlan`

*Status: **proposed** — 2026-08-16. Turns the Today iPhone cockpit (ADR-0038) from a
read-only projection into a light **execution** surface: on the day, you check stops off,
skip the ones you're not doing, defer the ones you'll do later, and tap through to a stop's
detail. The load-bearing decision is how "done" is stored — as a **reversible timestamp
overlay** on the existing `TripIdea`, not as the terminal `.done`/`.skipped` status. This
**supersedes the read-only restraint of ADR-0038 for Today specifically** (Journey stays
read-only). Preserves ADR-0001 (no server), ADR-0003 (execution state is domain state and
rides SQLite→CloudKit like everything else), ADR-0004 (the pull lifecycle), and ADR-0033
(floating "Anytime" stops).*

## Context

Dogfooding the Today preview (the `docs/handoff/today-day-preview.md` slice) surfaced a
concrete gap on an **Anytime day** — e.g. a Munich old-town walking tour where every stop
is a bare `.day` ("Anytime") schedule with a manual `dayRank` order (ADR-0033).

`TodayProjection` picks **NEXT** purely from the clock: the first stop whose nominal time
is at-or-after `now`. For a `.day` stop, that nominal time is *end of day* (23:59:59,
`TodayProjection.nominalDate`). So on an all-Anytime day **every stop is "upcoming" all day
long** — NEXT sticks on the first stop from morning to midnight, then all stops flip to
"past" at once. The clock cannot walk you through an *ordered* sequence; only the traveler
completing a stop can. Today has no way to record that, so the surface is inert on exactly
the kind of day it should shine on, and reads as a "death march" — a long fixed list with
no progress, no agency, and no way in.

Three facts made the fix small:

1. **`TripIdea` is the stop.** `ResolvedStop.entry` *is* the `TripIdea` row, so any column
   added to `TripIdea` is already carried into the projection with no extra plumbing.
2. **A completion vocabulary already exists but is lossy.** `TripIdeaStatus` has `.done`
   and `.skipped` (ADR-0004 post-trip terminals that feed visited-state back to the pool).
   But the itinerary is assembled from `status == .scheduled` only
   (`TripPlan.swift:242`), so flipping a live stop to `.done` **removes it from the plan** —
   it vanishes from Today *and* the planning Itinerary tab, can't be undone, and records no
   *when*. Status is a plan-lifecycle axis; execution is a different axis.
3. **Defer already has ops.** Moving a stop to another day or reordering within a day are
   existing `TripOperations` (`schedule(_:stopID:in:)`, `dayRank` reorder).

## Decision

### 1. Execution outcome is a reversible overlay, not a status change

Add two nullable columns to `TripIdea`, both `nil` for an untouched stop:

- `completedAt: Date?` — set when the stop is checked off (the instant, for ordering and a
  ledger).
- `skippedAt: Date?` — set when the stop is skipped ("not doing this").

They are **mutually exclusive** (a write that sets one clears the other), and the stop
**stays `.scheduled`**. The plan is unchanged by execution; completion and skip are a lens
Today lays over it. This is exactly the `Schedule`/`Certainty` idiom — flat columns behind
a total in-memory facade:

```swift
public enum StopOutcome: Equatable, Sendable {
  case pending
  case done(Date)
  case skipped
}
// TripIdea.outcome derives it: completedAt → .done, else skippedAt → .skipped, else .pending.
```

**Why overlay, not the `.done` status** (the decision Jon made, 2026-08-16): the plan stays
intact while you execute it (the planning Itinerary tab still shows the full day; a
half-walked tour doesn't look half-planned); completion is reversible (mis-tap → un-check);
it carries a timestamp (ordering, "done at 2:14"); and it keeps "did I plan this" cleanly
separate from "did I do this." The `.done`/`.skipped` **status** terminals remain what
ADR-0004 designed them for — a post-trip roll-up that feeds visited-state back to the pool;
a future step may fold completed stops into that terminal at trip's end, but that is a
distinct, later transition, not the live check-off.

### 2. Progress replaces the clock as the driver of NEXT and collapse — on the live day

`TodayProjection` gains an execution reading for the rendered day:

- **NEXT** = the first `.scheduled`, `.pending` stop in order that is still upcoming. On an
  Anytime day this is simply the first pending stop, so checking it off advances NEXT to the
  next pending stop — the missing mechanic.
- **Progress** = `done` of `done + pending` (skipped stops leave the denominator — you are
  not scored for opting out).
- **Collapse by outcome, not by clock.** Completed and skipped stops fold into a summary
  ("Done · N", and "Skipped · M" when any) at the top of the timeline; the remaining list is
  the pending stops and their connectors. This supersedes the time-based "Earlier today · N"
  collapse for the live day (real completion is a better signal than "the clock passed it").

Execution is **live-only**. When Today is *previewing* another day (the day-stepper is off
the live day), there are no outcomes to read: the full plan renders, check-off is disabled,
and only tap-through-to-detail is active. Preview stays a faithful read of the plan.

### 3. Defer reuses existing scheduling ops

"Defer" is a re-schedule, not an outcome:

- **Later today** — bump `dayRank` past the day's last stop (existing reorder).
- **To tomorrow** — `schedule(.day(day + 1), stopID:)` (existing), preserving nothing but
  the day move.

The stop stays pending; it simply moves. No new persistence.

### 4. Today owns the writes; the plan stays the source of truth

Check-off / un-check, skip / un-skip, and defer are mutations on `TripPlanningModel`
(which Today already holds), writing `TripIdea` through the existing DB seam. `TripPlan` is
`@FetchAll`-observed, so a write refreshes the plan and the projection recomputes — NEXT
advances and the list collapses reactively, no manual state.

### 5. Tap-through to detail

Each timeline row and the NEXT card become tappable, presenting the existing idea-detail
sheet (`TripPlanningModel.showDetail`) as a local `.sheet` from Today (iPhone-only surface;
a sheet avoids nested-navigation issues). Available in both live and preview.

## Consequences

- **ADR-0038's read-only restraint is lifted for Today** (Journey remains a read-only
  projection). Today now writes exactly two facts (`completedAt`, `skippedAt`) plus reuses
  existing reschedule ops. No new *table* or trip *concept* is introduced — the smallest
  step that makes execution real.
- **Sync:** the two columns are additive and nullable → a safe forward migration, and they
  ride SQLite→CloudKit like all domain state (ADR-0003). A household walking together sees
  each other's check-offs converge (last-write-wins per field is acceptable here).
- **The planning Itinerary tab is unchanged** — done/skipped stops still appear there as
  planned. Surfacing execution state in the planning surface is deliberately out of scope;
  Today is the execution lens.
- **Anytime days work.** The surface earns its place on the exact day type that motivated
  it, and the death-march feeling is answered with progress, collapse, and agency.

## Alternatives considered

- **Reuse the `.done`/`.skipped` status (zero schema).** Rejected as the live mechanic:
  irreversible, timestamp-less, and it strips the stop from the `.scheduled` plan the moment
  you tap — the plan and Today both lose it mid-trip. Kept as the intended *post-trip* pool
  roll-up.
- **A separate `StopCompletion` table.** More faithful to "an event," but a whole synced
  table (and a second sharing surface) for two nullable facts that belong to the stop is
  over-built. Columns on `TripIdea` match how `Schedule`/pinned-reservation data already
  live on the row.
- **Keep Today read-only; complete stops elsewhere.** Defeats the purpose — the cockpit is
  where you are when you finish a stop.

## Scope

First slice (see `docs/handoff/today-execution.md`): completion + progress, collapse by
outcome, skip + defer, and tap-to-detail. Live-gated writes; preview stays read-only.
Later: drag-to-reorder in Today, surfacing execution state in the planning tab, and the
end-of-trip roll-up of completed stops into the `.done` status for pool feedback.
