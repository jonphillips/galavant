# Effort — Stay-grouped day lens

Status: Ready
Summary: The hotel row folds into the day row: each stay becomes a labeled group of the days slept there, its label filters to the stay, and the separate lodging strip goes away.

Implements: jon-platform `docs/ios/ui-and-platforms.md` § Controls, and the 2026-10-31 canvas review with
Jon. Queued after [planning-chrome-alignment.md](archive/planning-chrome-alignment.md), which removes the day-chip
color dots this effort builds on. No schema change.

## Why

The lodging strip (`LodgingCapsuleBar`) does a real job: "everything at one sleeping location."
But it costs a full strip of map height, and the day chips beneath it carry no sense of where you
are. Grouping the days under their stay keeps the job and removes the strip.

## Design

One horizontal strip (`DayChipBar`), in this order:

`All │ [🛏 Père Bise]  Sat 22 · Sun 23 · Mon 24 │ [🛏 Le Cep]  Tue 25 · Wed 26 │ …`

- **Stay label** (`Icon.stay` + the stay's title, one line, truncated at about 18 characters, full
  title in the accessibility label): a chip-styled button that calls the existing
  `model.toggleCanvasStay(_:)`. Selected styling uses the house selected-chip rule. Keep a
  `BookingStatusGlyph` on it when the stay is `.toBook`, as `LodgingCapsuleBar` does today.
- **Day chips** follow their stay label, unchanged in behavior (`selectCanvasDay`, the Today label and
  ring).
- **Which group owns a day:** the stay you **sleep in that night**. A move day (checkout from A,
  check-in at B) belongs to B. The last day of the trip (checkout, no night) belongs to the stay it
  checks out of. Put this rule in a pure function on `TripPlan` (beside `stays(coveringDay:)`), with
  tests for: a move day, the last day, a day with no stay, and two overlapping stays (the
  later check-in wins).
- **Days with no stay** (e.g. an arrival day before the first check-in) sit ungrouped between
  **All** and the first stay label. Unstayed days in the middle sit ungrouped in sequence.
- **Separators:** a thin vertical divider between groups, nothing between days within a group.
- **Day label format:** `Sat 22` (abbreviated weekday plus day of month). When a day falls in a
  different month from the trip's first day, use `Jun 1`. Update `dayChipLabel` and its tests.
- **Selection stays mutually exclusive:** selecting a stay clears the day, and the reverse, as the
  model does now.

Remove `LodgingCapsuleBar` from the canvas and delete it if nothing else uses it.

## Done when

- The canvas has one strip. Stay labels filter to all activities at that stay, and day chips filter
  to the day.
- The day-ownership function is pure, lives in `GalavantSchema`, and has the four tests above passing.
- Month-crossing labels render correctly, with a test.
- VoiceOver reads "Auberge du Père Bise, stay, selected" and "Saturday May 22".
- `scripts/check-drift.sh` green. iPad screenshot of the Eastern France trip, plus a trip with an
  unstayed arrival day, in the PR.

## Out of scope

- Making stay titles shorter at the data level (a short-name field). Truncation is the default. A
  field is a schema change, and that is Jon's call if truncation reads badly on device.
