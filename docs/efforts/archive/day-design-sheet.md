# Effort — Day design: region, time zone and summary for each day, in Shape Trip

**Status:** Dispatched · **Summary:** Slice 1 of [ADR-0054](../../decisions/0054-day-design-in-shape-trip.md) (D1–D3). Shape
Trip gets one row per day for editing its region, time zone and summary. The itinerary's day headers stop being editors
and show the data instead: date, region, zone and a summary line, and a tap opens Shape Trip on that day. The guide's meal
lens shows each day's summary. No schema, migration, sync or hand-off change.

**Read first:** ADR-0054; ADR-0012 (per-day regions); [`trip-sketch-design.md`](trip-sketch-design.md);
`trip-time-model.md` §2 (day numbers, never dates); jon-platform `docs/ios/swiftui-forms.md`.

## Today

- `TripSketchSheet` ("Shape Trip", opened from the compass menu item in `TripPlanningView` and from the empty itinerary's
  "Sketch your days") has a Duration stepper, one row per region **span** with a region menu, and a "Set a region for
  specific days…" link (`RangeAssignView`). It edits a local `TripSketch` and saves live through `persistSketch`.
- `SectionHeader` (`TripItineraryDayHeader.swift`) shows the day label, the day note, and two editors:
  `DayRegionMenu` (or `UnassignedRegionChip`) and `DayTimeZoneMenu`, which shows only when
  `showsDayTimeZoneMenu(forDay:)` allows it.
- `TripDayNote` is the day's one-line summary. `TripDayNote.set` trims it and folds newlines. `dayNote(forDay:)` and
  `setDayNote(_:forDay:)` are on `TripPlanningModel+DaySheet.swift`, and `PlaceIdeaSheet` writes it as the day's
  "purpose".
- `dayTimeZone(forDay:)` and `setDayTimeZone(_:forDay:)` handle the override. `TripSketch.assign(_:toDays:)` handles the
  region.
- `GuideTripLens.MealDay` has the day, weekday, date, lunch, dinner and `alsoThatDay`. `RegionGuideTripLensView` draws a
  table on iPad and a row of 155-pt cards on iPhone.

## Part 1. Read-model (`GalavantSchema`)

A pure row value, so the sheet's per-day data is tested and the view stays thin:

```swift
public struct TripDayDesign: Identifiable, Equatable, Sendable {
  public var day: Int
  public var date: Date?                 // nil on an undated trip
  public var regionID: MapRegion.ID?
  public var timeZoneIdentifier: String? // the explicit override only
  public var summary: String?
  public var stayTitle: String?          // that night's lodging; the last day has no night
  public var id: Int { day }

  public static func rows(
    trip: Trip, dayRegions: [TripDayRegion], dayTimeZones: [TripDayTimeZone],
    dayNotes: [TripDayNote], stays: [ResolvedStay]
  ) -> [TripDayDesign]                  // days 1...lengthInDays; rows past the length are ignored
}
```

Use whatever stay type the model already resolves, if it isn't `ResolvedStay`. `day-reorder` adds a lock to this row
later, so keep it a struct the slice can extend.

`GuideTripLens.MealDay` gains `summary: String?`. `GuideTripLens.init` gains the trip's notes (`[Int: String]` or
`[TripDayNote]`). Wire it through `RegionGuideModel`'s existing observation. Don't build a plan per access: the lens
already reuses `TripPlanSnapshot`.

## Part 2. Shape Trip, one row per day

- The **Duration** section and the "Set a region for specific days…" link stay as they are.
- The **Days** section replaces the span rows with one row per `TripDayDesign`:
  - Line one: "Day 3 · Thu 15 Jul" (just "Day 3" when undated). At the trailing edge, the region chip (today's
    `regionMenu` style, assigning that one day through `sketch.assign(_:toDays: day...day)` + `persistSketch`) and, on a
    dated trip, the time zone chip (move `DayTimeZoneMenu` here; it no longer needs the
    `showsDayTimeZoneMenu` gate).
  - Line two: the summary, a `TextField("What's this day for?", axis: .vertical)` with `lineLimit(1...3)`. Commit with
    `setDayNote` when the field loses focus, on submit, and when the sheet closes. Don't write per keystroke: each write is
    a synced row.
  - A caption with the night's stay title, as the span rows show today.
- The region menu keeps "Add lodging for these nights" (for the region run that holds this day, seeded the way
  `addLodging(forSpan:)` does today) and "Attach regions…".
- **Opening on a day.** `TripSketchPresentation` carries an optional focus day. `sketchTapped(focusingDay:)` sets it. The
  sheet scrolls that row into view and focuses its summary field. The compass menu and the empty-itinerary prompt pass
  `nil`.
- Rows are flat, one `ForEach`. `day-reorder` makes them `reorderable()`, so don't group them into sections by region.

## Part 3. The itinerary's day header is display-only

`SectionHeader` for a day (the "To Be Scheduled" header is unchanged):

- Line one: the existing label, then `· Manchester` (the region name) in a slightly smaller font, secondary, no map icon,
  then `· BST` when the day has an explicit zone override. Unset values show nothing, and there's no "Set region" chip.
- Line two: the summary, `.subheadline`, secondary, `lineLimit(2)`, `textCase(nil)`.
- The whole header is a button to `sketchTapped(focusingDay: day)`, with the accessibility label "Edit day 3".
- Delete `UnassignedRegionChip` and `DayRegionMenu`. `DayTimeZoneMenu` moves with the sheet.
  `showsDayTimeZoneMenu(forDay:)` goes if nothing else reads it.
- **"Add a stop"** (`addStopRow`) becomes a small bordered button: `.buttonStyle(.bordered)`, `.controlSize(.small)`,
  the same label. Check that it doesn't turn the whole row into the tap target.
- Both itinerary lists (all days, and iPhone's focused day) use `SectionHeader`, so both change.

## Part 4. Summaries in the guide's meal lens

- **iPad (table):** under each day's row, the summary in `.caption`, secondary, `lineLimit(2)`, indented to line up with
  the Lunch column (`padding(.leading, 88)`, like "Also:"), and above "Also:".
- **iPhone (cards):** inside each card, under the weekday, the summary in `.caption2`, secondary, `lineLimit(3)`. Cards
  stay 155 pt wide.
- The nights lens is unchanged.

## Tests

- `TripDayDesign.rows`: dated and undated trips; a note, override and region past the trip length are ignored; stay
  title per night, with none on the last day; a blank day has nil fields.
- `GuideTripLens`: a region day's `MealDay.summary` comes from that day's note, and a day without one is nil.
- Existing `TripSketch` and `TripDayNote` tests stay green.

## Done when

- `scripts/check-drift.sh` is green, plus headless app-target tests (the slice touches `TripPlanningModel`).
- No schema, migration, `cloudkit-expected-fields.txt` or hand-off change.
- Closeout adds a device gate: in Shape Trip, set a day's region, zone and summary; tap a day header and land on that day
  with its summary field focused; the header shows the date, region, zone and summary with no menus; "Add a stop" looks
  like a button; summaries show in the guide's meal lens on iPad and iPhone.
