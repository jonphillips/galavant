# ADR-0054: A trip's days are designed in Shape Trip, and the itinerary only shows them

*Status: **proposed** — 2026-11-08, ratified by Jon merging this ADR's PR. Efforts:
[`day-design-sheet`](../efforts/archive/day-design-sheet.md), then [`day-reorder`](../efforts/archive/day-reorder.md). Builds on
[ADR-0012](0012-per-day-region-framing.md) (per-day regions) and the trip sketch
([`trip-sketch-design.md`](../efforts/archive/trip-sketch-design.md)).*

Summary: Each trip day has three design facts: its region, its time zone, and a one-line summary of what the day is for.
All three are edited in one place, Shape Trip (the compass menu), with one row per day. The itinerary's day headers stop
being editors and just show the facts, so there's room for the summary. The guide's meal lens shows the summaries too. In
Shape Trip, days can be dragged into a new order, and a day's stops, summary, region and time zone move with it. A day
holding a booking can't move.

## Context

Jon wants a summary line for each day ("Concert in Manchester", "Recover"). The data already exists: `TripDayNote` is a
synced, one-row-per-day caption, shown under the day header and written only from the day's "+" sheet. What's missing
is room and a natural place to write it. Today the day header holds two editors, a region chip menu and a time zone menu,
and the compass menu's Shape Trip sheet edits regions by span. Jon's call (2026-11-08): move all of a day's design into
Shape Trip, show plain data on the itinerary, and add drag-and-drop day reordering.

## Decision

**D1. Shape Trip is the editor for a day's design.** One row per trip day, showing the day and date, a region menu, a time
zone menu (dated trips only), and an editable summary. Duration and "Set a region for specific days…" stay. The summary is
the existing `TripDayNote`. The "+" sheet's purpose field can keep writing it too, since both converge on one row.

**D2. The itinerary's day header is display-only.** Line one is the date label, then the region name in a slightly
smaller font with no map icon, then the zone abbreviation when the day has an explicit zone override. Line two is the
summary, up to two lines. Anything unset shows nothing. Tapping the header opens Shape Trip scrolled to that day, with its
summary field focused. That one tap replaces both menus. "Add a stop" becomes a small bordered button.

**D3. The guide's meal lens shows each day's summary** (ADR-0053 D8), beside or under that day's lunch and dinner.

**D4. Days can be reordered in Shape Trip, and a day moves as a unit.** Moving day *a* to position *b* moves the day's
scheduled stops (`dayNumber` only: day part, times and `dayRank` are unchanged), its summary, its region and its time
zone override. The days in between shift by one to fill the gap. **Lodging doesn't move.** A `TripStay` belongs to its
nights, not to a day's plan, so check-in and check-out days stay where they are.

**D5. Some days are locked.** A day can't be dragged, and a move that would shift it is refused, when:

- it holds a stop with a `pinnedDate` or `bookingStatus == .booked`. A reservation is on a real date, and `pinnedDate`
  re-derives the stop's day from that date anyway. Jon chose this over leaving the booking behind (2026-11-08), so a
  day's summary never ends up apart from its reservation.
- it's on a dated trip and its date is before today. A day that already happened doesn't get a new date.

The refusal names the day and the reason, for example "Thu 15 Jul has a booking: Erst".

**D6. A move is one transaction applying a pure permutation.** The permutation and the lock check are value types in
`GalavantSchema`, with tests. The write updates `TripIdea.dayNumber` and `TripDayRegion.dayNumber` in place.
`TripDayNote` and `TripDayTimeZone` derive their ids from `(tripID, dayNumber)`, so moved rows are deleted and
re-inserted under the new day's id. No schema change.

## Consequences

- No schema, migration or CloudKit change.
- Moved stops change date, so the next Calendar export moves their events. The `day-reorder` brief has the executor
  check that the export identity follows the stop, not the day.
- If Wendy edits a day while Jon reorders, each row's last writer wins. That's fine for a household of two.
- `reorderable()` on one flat collection works. The sectioned overload is unverified on Xcode 27.0 (open-questions,
  "cross-day drag"), so Shape Trip lists days flat, not grouped by region.
