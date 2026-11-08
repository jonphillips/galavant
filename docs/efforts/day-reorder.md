# Effort — Drag days into a new order in Shape Trip

**Status:** Ready · **Summary:** Slice 2 of [ADR-0054](../decisions/0054-day-design-in-shape-trip.md) (D4–D6). Shape
Trip's day rows become `reorderable()`. Moving a day moves its scheduled stops, summary, region and time zone override,
and the days between shift to fill the gap. Lodging stays with its nights. Days holding a booking, and days already past,
are locked. No schema change.

**Read first:** ADR-0054 D4–D6; ADR-0034 and ADR-0041 (calendar authority and export); `trip-time-model.md` §2 and §4
(`pinnedDate`); ADR-0033 (`dayRank`); the `swiftui-whats-new-27` skill on `reorderable()`.

**Depends on `day-design-sheet`** (its flat `TripDayDesign` rows). Start from a `main` that has it.

## Today

- Day-keyed rows: `TripIdea.dayNumber` (with `dayPart`, `startTime`, `endTime`, `dayRank`, `pinnedDate`,
  `bookingStatus`), `TripDayRegion` (random id), `TripDayNote` and `TripDayTimeZone` (ids derived from
  `(tripID, dayNumber)`), and `TripStay.checkInDay` / `checkOutDay`.
- `pinnedDate` re-derives a stop's `dayNumber` from its date when the start date changes, so a pinned stop can't follow a
  day's new position.
- Travel-mode overrides key on stop and stay ids (ADR-0043), so they aren't affected by day numbers.
- The calendar export keeps identities in `CalendarExportIdentityStore` and the reconciliation ledger.

## Part 1. Pure move and lock (`GalavantSchema`)

```swift
public struct DayMove: Equatable, Sendable {
  public var from: Int
  public var to: Int
  /// Old day → new day, for every day that changes. Moving 2 to 5 gives 2→5, 3→2, 4→3, 5→4.
  public func mapping() -> [Int: Int]
  public var affectedDays: ClosedRange<Int> { min(from, to)...max(from, to) }
}

public enum DayLock: Equatable, Sendable {
  case booking(title: String)    // a stop with pinnedDate, or bookingStatus == .booked
  case past                      // dated trip, the day's date is before today
}

public enum DayMoveRefusal: Equatable, Sendable, LocalizedError {
  case locked(day: Int, label: String, DayLock)   // "Thu 15 Jul has a booking: Erst"
}

extension DayMove {
  public func validate(locks: [Int: DayLock], dayLabel: (Int) -> String) -> DayMoveRefusal?
}
```

- `TripDayDesign` gains `lock: DayLock?`. `rows(…)` gains the trip's stops and `now`.
- A move is refused if any day in `affectedDays` is locked, including the one being dragged. A move to the same day does
  nothing.

## Part 2. The write (`TripOperations` or a new `TripDayMove.swift`)

`Trip.moveDay(_ move: DayMove, tripID:, now:, in db:) throws` runs as one transaction:

1. Re-read the trip's stops and recompute the locks **inside the transaction**, then validate. Throw the refusal if a
   lock appears that the sheet didn't know about (for example, Wendy just booked something).
2. Change `TripIdea.dayNumber` through `mapping()` for every stop in `affectedDays` (all stops there have
   `pinnedDate == nil`, because the move would otherwise be locked). Leave `dayPart`, times and `dayRank` alone.
3. Change `TripDayRegion.dayNumber` in place.
4. `TripDayNote` and `TripDayTimeZone`: read the affected rows, delete them, and insert them again under the new days with
   the derived ids.
5. Don't touch `TripStay`. Ignore rows past the trip length.

**Spike first:** check that the calendar export's identity for a stop follows the stop id, not `(trip, day)`, so the next
export moves the event instead of duplicating it. If it's keyed by day, raise it in the PR with
`question-for-architect` before building the rest.

## Part 3. Shape Trip

- Make the day `ForEach` `reorderable()`. Apply each drop through `moveDay`. The sheet's rows come from the database, so
  they redraw on their own afterwards.
- A locked row shows a lock symbol with its reason as a caption. If `reorderable()` can disable dragging one item, use it.
  If it can't, refuse the drop.
- A refused drop shows an alert with the refusal's text, and the order snaps back.
- **Summary drafts only for edited days** (from the #229 review). `TripSketchSheet` seeds `summaryDrafts` for every day
  when it opens, and `commitAllSummaries` writes them all on close. A summary Wendy changes while the sheet is open gets
  overwritten with the stale seeded value. Create a draft only when a field is edited, let the binding fall back to
  `dayNote(forDay:)` otherwise, and commit only edited days. A reorder also changes which day a draft belongs to, so
  commit or drop the drafts before applying a move.
- The footer gains one line: "Drag a day to move its stops, summary, region and time zone. Lodging stays with its
  nights."

## Tests

- `DayMove.mapping()`: forward and backward moves, adjacent days, first to last, and moving a day onto itself.
- `validate`: a lock inside the range refuses, a lock outside allows, and dragging a locked day refuses.
- `TripDayDesign.lock`: pinned, booked, past-dated, an undated trip (no past locks), and a skipped booking (still
  locked).
- `moveDay` against a database: stops, notes, zones and regions land on their new days; stays are untouched; derived ids
  match the new days; a lock added before the write makes it throw and leaves nothing changed; moving the day back
  restores the original layout.

## Done when

- `scripts/check-drift.sh` is green, plus headless app-target tests.
- No schema, migration or `cloudkit-expected-fields.txt` change.
- Device gate: drag a day in Shape Trip, and the itinerary shows its stops, summary, region and zone on the new day, with
  lodging unchanged; a booked day can't move, and dragging another day across it is refused with the reason; the moved
  stops' calendar events move on the next export.
