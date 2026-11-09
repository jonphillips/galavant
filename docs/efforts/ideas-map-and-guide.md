# Effort — Ideas map and Guide: pins open again, the tapped pin stands out, the Guide drops dead controls, and an open meal takes one tap

**Status:** Ready · **Summary:** Four small fixes on the Ideas map and the Region Guide, from Jon's iPad use on 2026-11-09.
Tapping a pin opens the idea again (a regression since #132). The focused idea's pin is drawn bigger and accent-colored,
and pans into view. While the Guide is open on iPad, the Ideas filter bars and browse buttons go away. In an open lunch or
dinner slot, a place goes in with one tap. Supersedes [`idea-pin-focus`](archive/idea-pin-focus.md). No schema change.

**Read first:** ADR-0044 (explore, then capture); ADR-0053 D8; the archived briefs
[`guide-dossier-panel`](archive/guide-dossier-panel.md) and [`guide-slot-filling`](archive/guide-slot-filling.md).

The four parts touch different code and can land in order in one PR. If Part 2's custom pin fights MapKit, ship Parts 1, 3
and 4, and say so on the PR.

## Part 1. Pin taps open the idea again

**Today:** on the iPad, tapping an idea's pin on the Ideas map does nothing. Tapping a row works.

- Pin to row to dossier shipped and passed on device in #132 (2026-09-27, DONE-LOG "Ideas map pin → its row"). The plain
  `.tag(idea.id)` against a `MapSelection<Idea.ID>` selection is **not** the cause: it was already that way in #132, and
  the trip canvas uses the same pattern.
- Since #132, two changes touched the pin-tap path:
  - **#222** added `selectedValue` to `PlaceSelectionMap`. An `.onChange(of: selectedValue, initial: true)` writes
    `mapSelection` back, and `handleMapSelection` returns early when the tapped id equals `selectedValue`. Now two writers
    own `mapSelection`: the handler clears it, and the `onChange` sets it again.
  - **#225** put the map inside `IdeaMapSplitView`'s `ZStack`, with the dossier panel over its trailing edge.

**Fix:** remove `selectedValue` from `PlaceSelectionMap` and `PoolMapView`. That puts `handleMapSelection` back to its #132
shape: any tagged value calls `onSelectValue` and clears the selection. `PoolMapView` is the only caller that passes it.
The highlight that `selectedValue` was meant to give comes from Part 2, which draws the focused pin itself and doesn't
rely on MapKit's selection.

If you find a different cause along the way (for example in #225's layout), fix that one and say so on the PR. The Region
Guide map uses the same `PoolMapView`, so the fix covers both.

## Part 2. The tapped idea's pin stands out

Carried over from `idea-pin-focus`. Its "Today" section blamed the missing highlight on MapKit's selection blinking off.
With Part 1, the app no longer uses that selection for the highlight at all.

- **Draw the focused idea yourself.** In `PoolMapView`, leave the focused idea out of the `Marker` loop and draw it last,
  as an `Annotation` at its coordinate. Make it a pin about 1.5× the marker size, filled with the accent color (unlike the
  pulled and unpulled tints), with a white stroke, a soft shadow, and the kind's symbol inside. Its content is a `Button`
  that calls `onSelect`, as the trip canvas's `CanvasPreviewPin` does. Don't tag it.
- **Bring it into view.** When focus changes to an idea outside the visible region, pan the camera to center it, keeping
  the current span. Don't zoom.
- **Every source sets focus:** a list row, a guide card, a trip-lens stop (`RegionGuideModel.tripStopTapped` with an idea
  id; today it opens the dossier but doesn't set focus), and a pin. Closing the dossier clears focus.
- **iPhone too.** `IdeasScreen` and `RegionGuideScreen` pass focus only on regular width today. Pass it on compact as well,
  so the pin just tapped stands out when the person switches from the list to the map.
- Moving `focusedIdeaID` into `IdeasListModel` and `RegionGuideModel` is allowed, and better for testing.
- The trip canvas map isn't part of this.

## Part 3. The Guide drops the Ideas browse controls (iPad)

**Today:** on regular width, `IdeasScreen.content` swaps the Guide in for the list and map. But `capsuleBar`,
`quickFilterBar`, and the toolbar's Filter, Define Region, Guide, and Add Idea stay on screen, and none of them affect the
Guide. Add Idea is worse than useless there: `addIdeaButtonTapped` sets `model.destination = .form`, which replaces
`.guide` and closes the Guide.

- While `model.destination` is `.guide` on regular width, hide `capsuleBar`, `quickFilterBar`, and those four toolbar
  items. The Guide keeps its own header, map POI capture, and Back. The space goes to the Guide.
- iPhone is unchanged. There the Guide is a pushed screen, so the Ideas chrome isn't visible anyway.
- The Guide button stays in the Ideas toolbar.

## Part 4. An open meal slot takes a place in one tap

**Today:** tapping an open lunch or dinner cell narrows the cards to places not known to be closed for that meal
(`GuideSlotFocus.Content.open`). To put one there, the person opens its dossier, opens Add to Trip, and finds the same slot
again in the menu.

- **Look up the slot's row.** Add `GuideSlotMenu.row(day:meal:) -> Row?`, which returns the row for that slot (id
  `"\(day)-\(meal.rawValue)"`). The row already carries the action, or nil plus the reason it's disabled ("Closed
  Thursdays"), so closures behave exactly as in the menu.
- **From the dossier:** while an open slot is focused, the dossier's bottom bar leads with a prominent button,
  **Put in Wed lunch** (the focus's day label: the weekday on a dated trip, "Day 5" otherwise). The full Add to Trip menu
  stays beside it as a secondary control. If the row is disabled, the button is disabled and its reason shows beneath it.
- **From the card, without opening it:** in open-slot focus, each card gets a leading swipe action **Put here** and a
  context menu item **Put in Wed lunch**. Leave both off when the row is disabled. This follows jon-platform
  `docs/ios/ui-and-platforms.md` § Row actions: no visible buttons on the row.
- Both paths run `model.addToTrip(row.action, ideaID:)`, so the success haptic fires as it does today. The slot is now
  filled, so focus switches to the filled view on its own ("Showing options for Wed lunch"), and the person sees what they
  chose.

## Tests

- `GuideSlotMenu.row(day:meal:)`: an open slot returns its `.schedule` row, a slot closed that day returns a row with a nil
  action and its reason, and a day with no such slot returns nil.
- If focus moves into the models: each tap source sets the focused id, and closing the dossier clears it.
- App target: in open-slot focus, Put in runs `addToTrip`, and the focused slot reads as filled afterwards.
- Parts 1 and 3 are compile-only, plus the device gate.

## Done when

- `scripts/check-drift.sh` is green, and the app-target tests ran headless and passed (`verification.md`). Compile only, with
  no simulator walkthrough.
- The closeout carries this gate, word for word, with `--gate`:

  > **Ideas map and Guide (`ideas-map-and-guide`).** On the iPad, TestFlight build. In Ideas, tap a pin: its row scrolls
  > into view and tints, the dossier slides in, and the pin is bigger and accent-colored. Tap a row for an idea that's off
  > the map: its pin pans into view, highlighted. Close the dossier: the pin goes back to normal. Open Guide: the trip pills,
  > filter chips, and Filter / Define Region / Guide / Add buttons are gone. Tap a pin in the Guide and in the trip lens: the
  > same highlight. Tap an open lunch, tap a place, and Put in: the slot fills and shows its option. Swipe another card in an
  > open dinner and Put here. Then on the iPhone: tap a row, switch to the map, and its pin stands out.
