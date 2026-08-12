# ADR-0033: Floating untimed stops — an "Anytime" stop holds a position in the day, not a clock time

*Status: **accepted** — 2026-07-10. The schema, sort/anchor, and `suggestedTime` core
(Slices 1–3, 5) shipped and unit-tested; the **UI (Slice 4)** shipped 2026-07-10 — a stop
clock-time editor (`StopTimeSheet`) that pre-fills `suggestedTime`, and a **menu-based**
"Move Earlier / Later in Day" that writes `dayRank` via `reorderDayStops` (drag stays blocked by
the Xcode 27 beta 1 `List` drop-timeout, docs/KNOWN-ISSUES.md). **Refined 2026-08-11:** dogfooding
showed that refusing to put an Anytime stop before the first scheduled event was a real planning
failure. An explicitly moved leading Anytime stop receives a negative `dayRank` marker and sorts
one minute before the first timed/daypart anchor; untouched existing stops retain their historical
end-of-day behavior. Refines the day-relative time
model (docs/trip-time-model.md §2, ADR-0004)
and ADR-0010 (freeform stops). Feeds ADR-0030's one-tap pull+schedule and the now-marker/travel-leg
timeline. Prompted by a review of Tripsy's activity docs (untimed activities "can be placed
anywhere in your itinerary, even between timed events").*

## Context

`Schedule` (GalavantSchema/Schedule.swift) already distinguishes four placements: `.unscheduled`,
`.day(n)` ("Anytime"), `.daypart(n, part)`, `.timed(n, start, end?)`. So an **untimed on-a-day
stop already exists** — "wander the old town" on day 3 with no clock time is a legal `.day(3)`.
Two things make it a second-class citizen today, and a scan of Tripsy's itinerary UX threw both
into relief:

1. **It piles at the bottom of the day.** `Schedule.intraDaySort` sends both `.day` and
   `.unscheduled` to `endOfDay` (`24*60+1`). The day sort is
   `(dayNumber, intraDaySort, shortlistRank)` (TripPlan.swift:172). So every untimed stop sorts
   *after* every timed stop, and the intra-day tiebreaker among untimed stops is
   **`shortlistRank` — a pool-shortlist rank, not an itinerary position.** A user cannot drag
   "coffee, sometime after the museum, before the 2pm tour" to sit *between* the 10:00 and 14:00
   stops, and cannot reorder two Anytime stops within the day at all without reshuffling the
   shortlist. Tripsy's model is the opposite: an untimed activity flows wherever you drop it,
   *including between timed events*.

2. **Promoting or moving a stop starts from a blank time.** When a user gives an Anytime stop a
   time, or drags a `.timed` stop to another day, nothing proposes a sensible slot from its
   neighbors. Tripsy suggests a time "based on other activities on the day in question." We have
   the tested `scheduleStop` op (ADR-0030) but no pure helper that *derives* the suggestion.

This is not new schema — `.day`/`.daypart` carry the state. It is a **product decision about how
untimed stops behave in the timeline**: are they an end-of-day pile ordered by pool rank, or
positioned citizens of the day's flow?

## Decision

**An untimed ("Anytime") stop is a positioned citizen of its day.** It holds an explicit
intra-day order independent of clock time, so it can sit between timed stops; and a pure helper
proposes a time when the user chooses to give it one.

### 1. A per-stop intra-day rank replaces `shortlistRank` as the day tiebreaker

Add `TripIdea.dayRank: Double` (flat column, ADR-0006), the stop's manual order **within its
day**. The scheduled/itinerary sort key becomes:

```
(dayNumber, schedule.intraDaySort, dayRank)   // was: … , shortlistRank
```

- **Timed and dayparted stops** keep anchoring by `intraDaySort` (clock start / band hour) —
  their order is still driven by time, as today. `dayRank` only breaks ties among stops that
  share a sort bucket.
- **Bare `.day` "Anytime" stops** are the case that changes. They no longer collapse to
  `endOfDay`: an Anytime stop takes the `intraDaySort` of the stop it is dropped **after**
  (§2), so it interleaves. `dayRank` orders Anytime stops that land in the same gap and is what
  drag-to-reorder writes. `Double` lets an insert-between reuse the neighbors'-midpoint trick
  (no full renumber); a periodic normalize keeps values sane.

`shortlistRank` returns to meaning only what its name says — order in the shortlist pile — and
stops doubling as an accidental itinerary tiebreaker.

### 2. Anytime stops interleave via an anchor, not a forced end-of-day

A positioned Anytime stop resolves its sort key from its **anchor** — the `intraDaySort` of the
timed/dayparted stop it sits after in the day's manual order. The anchor lives in the **day
builder**, not on `Schedule.intraDaySort` (which stays a context-free value — it can't see its
day's other stops). The shared helper `TripIdea.effectiveIntraDaySort(_:)` walks a day's stops in
`dayRank` order, tracking the running `intraDaySort` of the most recent timed/dayparted stop; each
bare `.day` Anytime stop adopts that running anchor. Because the walk is `dayRank`-ordered, an
anchor always has a lower `dayRank` than the stop it anchors, so the final `(effectiveKey, dayRank)`
sort seats the Anytime stop *right after* its anchor and before the next timed stop. Both the
day-by-day builder (`TripIdea.itinerary` via `orderedDayStops`) and the timeline weave
(`TripPlan.itineraryItems`, which interleaves check-in/out boundaries) key off the same
`effectiveIntraDaySort`, so the two surfaces agree.

An Anytime stop with **no timed/dayparted stop before it** in `dayRank` order keeps **end-of-day**
placement (today's behavior) — nothing regresses for stops the user never positioned. (A
consequence: placing an Anytime stop *before the day's first timed stop* isn't expressible via the
anchor alone — give it a daypart, which already interleaves.)

**Slice 4 resolution (2026-07-10):** we **kept** this end-of-day rule rather than teaching
`effectiveIntraDaySort` a "before-first" anchor. A before-first case would have flipped the shipped
`anytimeStopWithNoPrecedingTimedStopStaysAtEndOfDay` test and, worse, would have re-seated
already-dogfooded Anytime stops (whose migrated `dayRank = shortlistRank`) at the *top* of their
day on the next TestFlight build — a real regression for the exact "stops the user never
positioned" the rule protects. Instead the reorder UI **enforces the boundary**: "Move Earlier"
disables once a bare Anytime stop sits right after the day's first timed/dayparted stop. This still
covers the ADR's two motivating cases — reorder Anytime stops among themselves, and walk "coffee"
up across the 14:00 stop into the 10:00–14:00 gap — because crossing *up* past a non-first timed
stop re-anchors to the earlier one (expressible); only crossing above the *first* timed stop is
refused. To seat a stop ahead of the day's first timed stop, give it a daypart.

### 3. `Schedule.suggestedTime(...)` — a pure helper, not a write

A pure function in GalavantSchema:

```swift
extension Schedule {
  /// A proposed "HH:mm" start for a stop being given a clock time, from the timed
  /// stops that bracket its position. Nil when neither neighbor is timed.
  static func suggestedTime(after previous: Schedule?, before next: Schedule?) -> String?
}
```

Implemented on the two bracketing `Schedule`s rather than the ADR's original `ResolvedStop`
sketch — the neighbors' start/end times are all it needs, so it stays free of the resolve layer,
and the app computes the two neighbors from the ordered day. It reads neighbor start/end times and
proposes a slot (after the previous stop's end, before the next stop's start; a default block —
`Schedule.suggestedGapMinutes` — when only one side is timed; the midpoint when the two collide).
**It never writes.** The two call sites are pure app actions:

- **Promote an Anytime stop to timed** — the time editor pre-fills `suggestedTime(...)` instead
  of a blank field; the user confirms or edits, then the existing timed-write op runs.
- **Move a `.timed` stop to another day** (ADR-0030's cross-day move, the itinerary drag) — the
  destination time pre-fills from the new day's neighbors rather than carrying the old day's
  clock time blindly.

This is the STYLE §functional-core pattern: a total pure function over
`(candidate placement × day's ordered stops)`, trivially unit-tested, no I/O.

### 4. Timeline behaviors: Anytime stops are timing-neutral

An Anytime stop has no clock time, so — unchanged from today, now stated as intent — it anchors
**no travel-leg ETA** and never trips the now-marker's "you're running late." It draws its row
in position with an "Anytime" (or daypart) label. The now-marker still lands between the timed
stops whose real times bracket the current moment; Anytime stops flow around it by `dayRank`.

### 5. No new placement case; dayparts stay the coarse-time option

We do **not** add a "floating" enum case. `.day(n)` *is* the floating stop; `.daypart(n, part)`
remains the "morning/afternoon/evening" coarse anchor (it already interleaves via
`part.sortHour`). The four-case `Schedule` (STYLE §3, impossible-states) is unchanged. Freeform
stops (ADR-0010) are born `.day(n)` or in the To-Be-Scheduled bucket and get all of the above for
free — a "lunch break" is the canonical floating stop.

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **Keep the end-of-day pile** (today) | Rejected — the reported gap. Untimed stops can't sit between timed events and can't be reordered within a day except by reshuffling the shortlist. |
| **Fully manual order; time is a display label** (pure Tripsy model) | Rejected. Throws away time-primary sorting, which the now-marker, travel legs, and the start-day solver all read. Timed stops staying time-sorted is a feature, not a limitation. |
| **Reuse `shortlistRank` as the intra-day rank** | Rejected — it conflates two orders (shortlist pile vs. day position); dragging within a day would silently reorder the shortlist. The bug we're removing. |
| **Integer `dayRank` with full renumber on insert** | Rejected for churn — every between-insert rewrites the tail (and syncs N rows via CloudKit). `Double` + midpoint insert + lazy normalize is the standard cheap answer. |
| **Add a fifth `.floating` enum case** | Rejected — `.day(n)` already means exactly this; a new case duplicates it and forces every switch to handle a redundant state. |
| **Model the LLM/suggest-time as a tool the model calls** | Rejected — `suggestedTime` is deterministic arithmetic over neighbor times; no model needed, and it keeps the write on the human tap (ADR-0030/ADR-0004 line). |
| **`dayRank` tiebreaker + anchored Anytime interleave + pure `suggestedTime` (chosen)** | Leanest fit: additive column, `Schedule` enum untouched, timed stops stay time-sorted, untimed stops gain real positions, suggestion is a tested pure function. |

## Relationship to prior decisions

- **docs/trip-time-model.md §2 (day-relative):** unchanged — everything still keys off day
  number; `dayRank` is intra-day order, not a date.
- **ADR-0004 (schedule lifecycle) / ADR-0030 (one-tap pull+schedule):** `suggestedTime` feeds the
  *human* schedule action; the model still never writes. A pulled suggestion can land as an
  Anytime stop and be positioned later.
- **ADR-0010 (freeform stops):** freeform stops are the archetypal floating stop; they inherit
  `dayRank` and `suggestedTime` with no extra work. Supersedes ADR-0010's note that "new freeform
  stops append to the bottom via `nextStopRank`" — day position is now `dayRank`.
- **now-marker / travel legs (M3):** untimed stops remain timing-neutral (§4); no leg, no
  lateness — now made explicit rather than incidental.
- **ADR-0006 (flat Trip/TripIdea columns):** `dayRank` is one additive flat column.

## Consequences

- **GalavantSchema:** one additive `TripIdea.dayRank: Double` column (SQLiteData additive-column,
  no migration friction; CloudKit-friendly). `Schedule.intraDaySort` gains anchor-awareness;
  `TripPlan.scheduled` / `TripIdea.itinerary` sort on `dayRank` not `shortlistRank`; new pure
  `Schedule.suggestedTime`. All unit-tested in-memory (STYLE functional core).
- **Ops:** a `reorderStop(within day:, to:)` writing `dayRank` (midpoint insert); promote/move
  ops call `suggestedTime` to seed the time editor. Reuses existing tested write paths otherwise.
- **App:** itinerary drag lets an Anytime row drop between timed rows (writes `dayRank`); the time
  editor pre-fills the suggestion; `swiftui-specialist` checkpoint; device install on the
  iPad Pro 13-inch sim ([[preferred-review-sim]]).
- **No CloudKit sync-registration change** — `dayRank` rides `TripIdea`'s existing registration.

## Slices

- **Slice 1 — schema + sort ✅:** `TripIdea.dayRank` column + setter; switch `scheduled`/`itinerary`
  tiebreaker to `dayRank`; in-memory tests that Anytime stops now order by `dayRank` and timed
  stops are unaffected.
- **Slice 2 — anchored interleave ✅:** the anchor lives in the day builder
  (`TripIdea.effectiveIntraDaySort` / `orderedDayStops`), shared with `TripPlan.itineraryItems`;
  tests that an Anytime stop dropped after the 10:00 stop sorts before the 14:00 stop, that stops
  share an anchor by `dayRank`, and that an un-anchored Anytime stop stays at end-of-day.
- **Slice 3 — `suggestedTime` ✅:** the pure `Schedule.suggestedTime(after:before:)` helper +
  table-driven tests (both-sides, one-side, collide→midnight-clamp, empty, non-timed, malformed
  neighbor).
- **Slice 4 — UI ✅ (2026-07-10):** a stop clock-time editor (`StopTimeSheet`, wired through a new
  `Destination.stopTime` + `TripPlanningModel.editStopTime`/`saveStopTime`) that pre-fills
  `Schedule.suggestedTime` from the stop's ordered-day neighbors — net-new, the app's first stop
  time editor. `StopMenu` gains a **"Set Time… / Change Time…"** affordance, a bare-Anytime-only
  **"Move Earlier / Later in Day"** pair (`moveStopEarlier`/`moveStopLater` → `reorderDayStops`,
  with "Move Earlier" disabled at the first-timed boundary per §2), and its Move-to-Day now seeds a
  timed stop's clock from the **destination** day's neighbors (`moveToDay`). Drag stays blocked
  (Xcode 27 beta 1 `List` drop-timeout, KNOWN-ISSUES; the itinerary row stream is heterogeneous, so
  `.onMove` needs a `ScrollView`/`LazyVStack` rebuild). `swiftui-specialist` checkpoint done; built
  and installed on the iPad Pro 13-inch (M5) sim.
- **Slice 5 — docs ✅:** flipped to accepted (core); ROADMAP / BACKLOG / trip-time-model note;
  superseded ADR-0010's `nextStopRank` line.
