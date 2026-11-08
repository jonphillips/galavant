# Effort — The tapped idea's pin stands out on the map

**Status:** Ready · **Summary:** Tapping an idea in the Ideas list, the region guide or the guide's trip lens makes its
pin on the map bigger and a different color, and brings it into view if it's off screen. Today this relies on MapKit's own
marker selection, only on iPad, and Jon sees no change. No schema change.

**Read first:** ADR-0044 (explore, then capture); [`guide-dossier-panel`](archive/guide-dossier-panel.md) (the dossier over
the map).

## Today

- `PoolMapView` draws each idea as a `Marker` tinted by `tint(for:)` (pulled or not) and passes `selectedIdeaID` to
  `PlaceSelectionMap`. That sets MapKit's `mapSelection`, which is the only highlight.
- `PlaceSelectionMap.handleMapSelection` sets `mapSelection = nil` right after a pin tap, and `selectedIdeaID` only puts it
  back when the focus id changes. So the native selected look can blink off.
- `IdeasScreen` and `RegionGuideScreen` keep `focusedIdeaID` as view state and pass it only when
  `horizontalSizeClass == .regular`. iPhone passes nil.
- Focus sources are list row taps (`IdeasScreen`), guide card taps (`RegionGuideScreen`) and pin taps. A trip-lens tap
  (`RegionGuideModel.tripStopTapped`) opens the dossier but doesn't set `focusedIdeaID`.

## Design

- **Draw the focused idea yourself.** In `PoolMapView`, leave the focused idea out of the `Marker` loop and draw it last,
  as an `Annotation` at its coordinate: a pin about 1.5× the marker size, filled with the accent color (unlike the
  pulled/unpulled tints), with a white stroke and a soft shadow, and the kind's symbol inside. Give it the same `tag`, so
  tapping it still calls `onSelect`. It no longer depends on MapKit's selection, so the blink doesn't matter.
- **Bring it into view.** When focus changes to an idea outside the visible region, pan the camera to center it, keeping
  the current span. Don't zoom.
- **Every source sets focus:** list row, guide card, trip-lens stop (`tripStopTapped` with an idea id), and pin. Closing
  the dossier clears it.
- **iPhone too.** Pass the focus on compact width as well. When the person switches from the list to the map, the pin they
  just tapped stands out.
- The trip canvas map isn't part of this.

## Tests

- If focus moves into `RegionGuideModel` or `IdeasListModel` (allowed, and better for testing): each tap action sets the
  focused id and closing the dossier clears it. Otherwise this is compile-only, plus the device gate.

## Done when

- `scripts/check-drift.sh` is green.
- Device gate, on iPad and iPhone: tap an idea in Ideas, then in the guide, then in the trip lens, and its pin is bigger
  and accent-colored, and it pans into view when off screen; tap a pin and it stays highlighted; close the dossier and it
  goes back to normal.
