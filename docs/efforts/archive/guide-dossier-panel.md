# Effort — Dossier over the map: read a place without leaving the list

**Status:** Dispatched · **Summary:** Slice 3.1 of [ADR-0053](../../decisions/0053-taste-record-and-region-guide.md) (D8).
Tapping a place in the region guide or in Ideas opens its dossier over the map instead of in place of the list. On iPad it's
a panel floating over the map's trailing edge. On iPhone it's a sheet that opens at half height. Tapping another place swaps
what's in it, so there's no back step. No schema, migration, sync, or hand-off change.

**Read first:** ADR-0053 D8; the mockup [`region-guide-trip-lens.html`](../../mockups/region-guide-trip-lens.html), frames 1
and 3; the archived [`idea-dossier`](idea-dossier.md) brief (what the dossier is) and
[`region-guide`](region-guide.md) brief (the screen).

## Today

- `IdeaMapSplitView` (`Galavant/Ideas/IdeaMapSplitView.swift`) is the regular-width container for both `IdeasScreen`
  (line ~139) and `RegionGuideScreen` (line ~28). When `ideaID` is set, it **replaces** the list column with
  `IdeaDetailView(ideaID:canEdit:onBack:)`. That replacement is the tap-in, tap-out Jon found tedious.
- On compact width, both screens push the dossier with `.navigationDestination(item: $model.destination.dossier)`.
- `IdeaDetailView` gets its title and its **Edit** button from the enclosing navigation bar (`.navigationTitle`,
  `.toolbar`). Its `onBack` shows a Back button on regular width only. It also presents its own edit sheet and photo cover.
- Trip and Today push `IdeaDetailView` too, with `stopContext`. They stay exactly as they are.
- Both screens already track a focused idea (`focusedIdeaID`) and pass it to `PoolMapView` as `selectedIdeaID` on regular
  width.

## Part 1. The dossier's chrome is a value, not an accident of where it's hosted

Replace `onBack` with one enum, so a panel and a pushed screen can't be half-configured:

```swift
extension IdeaDetailView {
  enum Chrome {
    case navigationBar                    // pushed: title and Edit in the bar (Trip, Today)
    case panel(onClose: () -> Void)       // hosted over the map: its own header row
  }
}
```

- **`.navigationBar`** is today's behavior minus the Back button, which only `IdeaMapSplitView` used.
- **`.panel`** draws a header row at the top of the dossier, above the list: the place's name (one line, headline), an
  **Edit** button when `canEdit`, and a close button (`xmark`, labelled "Close"). It sets no navigation title or toolbar
  items. The edit sheet and photo cover work the same in both.
- **Don't wrap the panel in a `NavigationStack`.** A nested stack inside the split layout is the trap that bit us on iPad
  before. The panel is an overlay with its own header, and that's all it needs.

## Part 2. iPad: a floating panel over the map

`IdeaMapSplitView` keeps its name and callers, and changes what it does with `ideaID`:

- **The list column always shows.** The map takes the rest of the width, as now.
- **When `ideaID` is set,** the map gets an overlay aligned to its trailing edge: `IdeaDetailView(…, chrome: .panel(onClose:))`,
  360 points wide, inset 12 points from the top, bottom, and trailing edges, with a 16-point corner radius, a shadow, and the
  system background. Give it `.id(ideaID)` so a new place replaces the old one rather than updating it.
- **Tapping another card or pin swaps what's in the panel.** Close clears the dossier, as `onBack` did. Keep `IdeasScreen`'s
  existing close behavior: drop the focus when the idea is no longer in the list.
- **The map stays usable.** It pans and zooms outside the panel. While the panel is open, the map gets
  `.safeAreaPadding(.trailing, 372)`, so framing and the selected pin land in the visible part, not under the panel.
- **The selected card stays highlighted,** and the selected pin stays selected, as now.
- **Animation:** the panel slides in from the trailing edge and fades. Swapping between places doesn't animate.

## Part 3. iPhone: a sheet that starts at half height

On compact width, `IdeasScreen` and `RegionGuideScreen` replace the dossier's `navigationDestination` with a sheet:

```swift
.sheet(item: $model.destination.dossier) { ideaID in
  IdeaDetailView(ideaID: ideaID, canEdit: true, chrome: .panel(onClose: { model.closeDossier() }))
    .presentationDetents([.medium, .large])
    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
}
```

- **The list or map stays usable behind the sheet** at half height, which is the "cover the map slowly" Jon asked for. Tapping
  another card or pin while the sheet is open swaps its content in place, without dismissing it. The destination case's
  `ideaID` changes, and the sheet's content takes `.id(ideaID)`.
- **The guide's own push from Ideas** (`destination.guide`) is unchanged. Only the dossier becomes a sheet.
- `Destination.dossier` keeps its payload. If the binding shape makes the swap dismiss and re-present, raise it on the PR
  rather than adding a second destination.

## Tests

- **App target:** the existing `RegionGuideModelTests` and Ideas model tests pass unchanged. Add one test per model: with a
  dossier open, tapping a different idea sets `destination` to that idea's dossier in one step, and `closeDossier()` clears
  it.
- **Package:** no change, so the suites pass unchanged.

## Out of scope

- The trip lens, slot strip, and Add to Trip. Those are [`guide-trip-lens`](../guide-trip-lens.md) and
  [`guide-slot-filling`](../guide-slot-filling.md).
- Trip and Today's dossier presentation (`.navigationBar`). Don't change it.
- Resizing or dragging the iPad panel, and remembering the iPhone sheet's height.

## Done when

- On regular width, tapping a card or pin in Ideas or the guide shows the dossier over the map, with the list still showing.
  Tapping another swaps it, and Close dismisses it.
- On compact width, the dossier is a sheet that opens at half height with the content behind it still usable.
- `IdeaDetailView` takes `chrome:`, with no `onBack` left. Trip and Today read exactly as before.
- `scripts/check-drift.sh` passes, and the app-target tests ran headless and passed (`verification.md`). Compile only, with
  no simulator walkthrough.
- The closeout carries this gate, word for word, with `--gate`:

  > **Dossier over the map (`guide-dossier-panel`).** On the iPad, TestFlight build. Open the Guide for a region with
  > restaurants. Tap a card: the dossier floats over the right side of the map, and the list stays put. Tap three more cards,
  > then a pin: each one swaps in with no back step. Pan the map with the panel open. Tap Edit, save, and close. Do the same
  > in Ideas. On the iPhone, tap a card: a half-height sheet. Tap another card behind it: it swaps. Pull it up to full height,
  > then close it. Open a stop from a trip and from Today: they look exactly as before. **Then judge:** Is the panel wide
  > enough to read? Does it cover pins you wanted to see?
