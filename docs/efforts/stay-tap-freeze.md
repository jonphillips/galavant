# Effort — Tapping a stay freezes the planning column

**Status:** Ready · **Summary:** On the TestFlight build with the stay-grouped lens, tapping a stay
label in the day strip turns the capsule dark and freezes the app, every time. Jon reported it
2026-10-31. The likely cause is a feedback loop that #189 added: the itinerary collapses the trip header
based on a scroll measurement that the header's own removal changes. A stay tap is the one lens tap
that programmatically scrolls the whole-trip list, so it starts the loop. Make the collapse
measurement independent of the header, add hysteresis, and stop rebuilding the plan on every body
pass. No schema, sync or contract change.

From #189 (planning chrome alignment) and #191 (stay-grouped day lens). Jon's TestFlight crash
reports for this hadn't reached App Store Connect when the brief was written. The devices hold no
Galavant crash log either, which fits a hang that was force-quit.

## The loop

- `TripItineraryView` reports `contentOffset.y + contentInsets.top > 40` through
  `onScrolledPastHeader`. `TripDetailContent` sets `headerCollapsed` from it.
- The header (`TripHeaderImageView`, 160 pt, shown only when `usesColumn`) lives in the **list's own**
  `.safeAreaInset(edge: .top)`. Collapsing it shrinks `contentInsets.top` by about 160 pt while
  `contentOffset.y` stays put, so the measured value drops by the same amount.
- Scrolled anywhere between 40 and about 200 pt, the measurement flips: collapse → value < 40 →
  expand → value > 40 → collapse. Each flip animates (`.animation(.easeOut(duration: 0.2), value:
  headerCollapsed)`) and re-lays out the whole-trip list.
- **Why a stay tap:** `toggleCanvasStay` sets `sheetTab = .itinerary`, clears the day lens (so the
  list becomes the full trip), and `.task(id: scrollDay)` calls `proxy.scrollTo(.day(checkInDay))`.
  That lands the list at an offset that oscillates. A day tap swaps in a one-day list and never
  scrolls. **All** doesn't scroll either.
- Each pass is also expensive: `TripDetailContent.tripTimeZoneTaskID` reads `model.plan.itinerary`
  (a full `TripPlan` rebuild) on every body evaluation, and the map's stay framing rebuilds the plan
  again. `plan` is a computed property, so every read rebuilds it, the same hazard behind the August itinerary hang.

**Confirm before fixing.** Add a temporary log in the `onScrolledPastHeader` action, or set a
breakpoint, and tap a stay on an iPad trip with a header image. A stream of alternating values
confirms the loop. If the value doesn't alternate, stop and post what you saw as a
`question-for-architect` before changing anything. Take a Time Profiler or hang trace on the
tap if you can. Say in the PR which of these you used. If the freeze also happens on iPhone (no header
there), the loop isn't the whole story: say so in the PR.

## 1. Measure past the header, not including it

- Move the header out of the list's `safeAreaInset`. Put it above the list panel (for example in a
  `VStack` with the panel) so showing or hiding it changes the list's frame and leaves its content
  insets alone. The segmented picker and the "Times in" line stay pinned as they are now. Keep the
  current look: the header slides away and the picker stays pinned at the top of the column.
- Whatever layout you choose, the value fed to `onScrolledPastHeader` must not change when the
  header appears or disappears. State in the PR why yours holds that.

## 2. Hysteresis

- Collapse when scrolled past 40 pt. Expand only when back at the top (≤ 0). Put the rule in a small
  pure function (`next(collapsed:offset:) -> Bool`) next to the view, and unit-test it in
  `GalavantTests`: below, between and above the band, from each starting state.
- Report a change only when the result differs from the current state.

## 3. Don't rebuild the plan per body pass

- `tripTimeZoneTaskID` builds its key from `model.plan.itinerary` on every evaluation. Key the task
  on cheaper inputs: the trip ID, its start date, the region IDs, and the scheduled stops' coordinates
  taken from `entries` or `ideaByID` without building a `TripPlan`. Or compute it once in the model
  when those inputs change. The key must still change exactly when the time zone could change.
- Leave the map's `frameSelection` alone unless the trace points at it. If it does, build the plan
  once per call, as it already tries to.

## 4. The capsule

- Jon saw the stay capsule turn dark when tapped. Check on device after §§ 1–3 whether the selected
  styling (`.tint.opacity(0.2)` fill) still renders dark. If it does, that's a separate styling bug:
  fix it to match the day chip's selected look and say so in the PR.

## Tests

1. The hysteresis function (§ 2).
2. A `TripDetailContent`-level test isn't required. The device gate covers the behavior.

## Done when

- §§ 1–3 are in and the loop was confirmed before the fix (§ "Confirm before fixing").
- Tapping a stay on iPad scrolls the itinerary to the stay's first day and the app stays responsive.
  The header collapses once and doesn't flicker.
- `scripts/check-drift.sh` green.

## Device gate (Jon, not executor)

Recorded in `device-passes.md`: on iPad and iPhone, tap each stay label on the Eastern France trip,
then a day, then All. No freeze, no header flicker, and the list lands on the stay's first day.
