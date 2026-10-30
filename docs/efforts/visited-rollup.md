# Effort — Visited roll-up: a finished trip marks its places visited

**Status:** Queued (2026-10-30), behind `seed-handoff-cleanups` · **Summary:** completion should be
inferred, not tapped (Jon, 2026-06-13). Once a dated trip is over, every idea it had on a day, and that
wasn't skipped, is marked **visited** in the pool, once per trip. The trip's own record of what was
planned, done and skipped is left exactly as it is. Adds one nullable synced column, `Trip.visitedRolledUpAt`,
so the architect escalates the PR to Jon, and the Production schema deploy comes before the next
TestFlight build.

From `docs/open-questions.md` § Designed / deferred, "Itinerary completion rollup". ADR-0004 designed the
done → visited feedback; ADR-0039 §1 moved the live check-off to a reversible overlay and left
"the end-of-trip roll-up … for pool feedback" for later. This is that roll-up.

## Decisions (approved by merging this plan)

1. **It flips `Idea.visited` and nothing else.** No stop moves to the `.done` status, and
   `completedAt` / `skippedAt` aren't touched. `.done` stops drop out of `TripPlan`
   (ADR-0039 Context 2), so using the terminal would empty every past trip's itinerary. The pool is
   what needs the signal; the trip keeps its history.
2. **Which stops count:** idea-backed stops (`ideaID != nil`) with status `.scheduled` and a day
   (`Schedule` not `.unscheduled`), excluding any with `skippedAt` set. A pending stop counts: nobody
   checks off every stop, which is the point of inferring. Stops in an alternatives ring count only if
   `completedAt` is set, since a ring means "one of these" and we can't tell which. Freeform stops have no
   pool idea, and considering, shortlisted, declined and skipped-status stops don't count.
3. **Once per trip, recorded in sync.** `Trip.visitedRolledUpAt: Date?` (nullable, additive). The roll-up
   runs only while it's `nil` and sets it in the same transaction. So if someone clears an idea's Visited
   flag afterwards, no device sets it again.
4. **Past trips count too.** The first run rolls up every dated trip that's already over, not only trips
   that finish from now on. Call this out in the PR.
5. **"Over" is `Trip.isPast(at:calendar:)`**, the definition the Trips list already uses for its
   Completed section. Pass the trip's calendar the way the Calendar reconciliation freeze does
   (`CalendarReconciliationModel` builds `tripCalendar` from the region time zone); fall back to
   `.current`.

## 1. Pure core, in `GalavantSchema`

- A value-type planner, for example `VisitedRollup.ideaIDs(for:trip:tripIdeas:now:calendar:)`, returns
  the idea IDs to mark, or none when the trip isn't over, isn't dated, or already has
  `visitedRolledUpAt`. All of Decision 2 lives here.
- An operation, for example `Trip.rollUpVisited(tripID:now:calendar:in:)`, re-reads the trip and its
  stops inside the write, runs the planner, sets `visited = true` on those ideas (an idea already visited
  is left alone), and sets `visitedRolledUpAt = now`. It's a no-op if the marker is already set. Take
  `now` as an argument; the caller supplies it from `@Dependency(\.date)`.

## 2. Schema

- Add `visitedRolledUpAt` to `Trip` with a migration in the next `DatabaseMigrationRegistrations` slot,
  following the existing nullable-column migrations. CloudKit sees a new field on `trips`, so the
  standing schema-deploy rule applies before any TestFlight build.

## 3. When it runs

- On launch and on scene `.active`, from the app level next to the existing scene hook in `AppContainer`.
  One write per trip that needs it; trips that don't need it cost a read.
- **Not while sync is still catching up.** Run only when sync is off, or the engine is running and not
  fetching (`isFetchingChanges == false`). On a fresh device, a trip's marker may not have arrived yet,
  and rolling up early would undo a cleared Visited flag. Skip and try again on the next activation.
- Silent: no banner. The pool's Visited filter and badges show the result.

## Tests

**Library** (`GalavantLibrary`):
1. The planner across Decision 2: pending scheduled counts; skipped is excluded; an unscheduled
   shortlisted stop is excluded; freeform is excluded; a ring member counts only with `completedAt`;
   a declined stop is excluded.
2. Not over → nothing; undated → nothing; marker already set → nothing; the day after the last day →
   the roll-up. Use the same boundary cases as the `isPast` tests.
3. The operation marks ideas and sets the marker in one transaction. A second call is a no-op, and an
   idea cleared after the first run stays cleared.
4. Stop statuses, `completedAt` and `skippedAt` are unchanged after the roll-up, and the past trip's
   `TripPlan` itinerary is the same before and after.
5. The migration adds the column, and existing trips read `nil`.

## Done when

- One PR on branch `effort/visited-rollup`. `scripts/check-drift.sh` is green and headless
  `GalavantTests` pass.
- One additive synced column; no other schema, sync-contract or identifier change. The PR says so at
  the top, for the architect's escalation.
- The completing PR:
  - adds a DONE-LOG entry and marks this brief Done in `docs/efforts/README.md`;
  - removes "Itinerary completion rollup" from `docs/open-questions.md`;
  - adds to `docs/device-passes.md`: under the standing **Schema deploy** gate, the `trips` field
    `visitedRolledUpAt` (a development build with sync on pushes it once a past trip rolls up; deploy to
    Production before the next TestFlight build). Under **Verification gates**: *open the app with a
    past trip in the library: its scheduled, not-skipped places show Visited in Ideas, and its itinerary
    still shows every stop. Clear Visited on one of them, relaunch on both devices, and it stays
    cleared;*
  - sets `docs/NEXT_UP.md` to the empty ticket, carrying the **Owed:** line over unchanged.
