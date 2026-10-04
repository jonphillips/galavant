# Effort — Today polish: live-day map rollover + bookings doc comment

**Status:** Done (2026-10-04) · **Summary:** two small fixes from the reviews of #145 and #143.
Both were left as merged-PR review nits, and nobody reads those afterwards. This brief makes them
real work. One is a bug in the Today day map; the other is a wrong doc comment.

No schema change, no sync change, and no new Directions requests.

## 1. The live day's map drops the device at midnight

`TodayDayMapCard` ([TodayDayMapCard.swift](../../Galavant/Today/TodayDayMapCard.swift)) frames the
camera on appear, when `day` changes, and once when the first device fix arrives on the live day
(the `oldCoordinate == nil` guard). The follow task is keyed on `shouldFollowDevice`, which is
`isLiveDay && tracking`.

**The bug.** Say the live day advances while the card is on screen, for example day 2 → day 3 at
midnight with Today open. `day` changes, but `shouldFollowDevice` stays `true`, so:

- the task isn't restarted;
- `coordinate` stays non-nil, so the first-fix `onChange` never fires again;
- `onChange(of: day)` calls `frameCamera()` with no device.

The device then drops out of the frame and stays out until the card is rebuilt.

**The fix.** In the `day` handler, call `frameCamera(including: deviceLocation.coordinate)`. This is
safe in the other two transitions:

- **Live → preview.** `frameCamera` already ignores the device when `!isLiveDay`.
- **Preview → live.** The follow task wasn't running on the preview day, so `coordinate` is already
  `nil`, and the restarted task's first fix frames as it does today.

Don't add a second framing rule. The brief's rules still hold: the camera frames on appear, on a
day change, and on the first fix, and later fixes move only the dot.

**Test.** The card's framing lives in the view, so there's no unit seam for the handler itself.
`MapFraming.box(for:including:within:)` already covers the framing math. Don't build a new seam just
for this one line. Add a device-pass line instead (below).

## 2. `TodayProjection.bookingsDue` doc comment

[TodayProjection.swift](../../GalavantLibrary/Sources/GalavantSchema/TodayProjection.swift) documents
`bookingsDue` as "Booked work due today or on the next trip day…". It's built from
`TripBookingRollup.toBook`, so it holds work that's still **to book**. Reword it to say so. For
example: *"Bookings still to make for today or the next trip day, in trip-rollup order."*

## Done when

- Both changes land in one PR on branch `effort/today-polish`.
- `scripts/check-drift.sh` is green. Headless `GalavantTests` pass (`docs/verification.md`), because
  this touches an app view.
- The completing PR:
  - adds a DONE-LOG entry;
  - sets `docs/NEXT_UP.md` to the next dispatch in plan order, exactly this block:

    ```
    # Next Up — ADR-0048 Slice 1: `.declined` status + trip documents

    **Slices:** effort `adr-0048-slice-1` (one PR, branch `effort/adr-0048-slice-1`)
    **Briefs:** `docs/efforts/adr-0048-slice-1-declined-and-documents.md`
    **Done when:** per the brief's "Done when"; verification per `docs/verification.md`.
    **Owed:** schema + sync change: the architect escalates the PR to Jon before merge. Jon's device
    gates and the CloudKit production promotion in `docs/device-passes.md` (not executor work).
    **Notes:** New status case 5 (never renumber) and one new synced table. No seed verb, no
    contract change, no Markdown dependency. Start from a fresh `main`.
    ```

  - marks this brief Done in `docs/efforts/README.md`;
  - adds one line to `docs/device-passes.md`: *with Today open on a live day across midnight (or a
    clock change), confirm the map keeps your position in frame on the new day.*
