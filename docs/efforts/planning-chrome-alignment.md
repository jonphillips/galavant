# Effort — Planning chrome alignment

Status: Ready
Summary: Trip planning adopts the house control conventions: one AI menu, day colors on the map only, quieter day headers and stop rows, and a hero image that collapses on scroll.

Implements: jon-platform `docs/ios/ui-and-platforms.md` § Controls (adopted 2026-10-31). Follows the
2026-10-31 design review of the trip canvas with Jon. No schema change. Sibling effort, queued next:
[stay-grouped-day-lens.md](stay-grouped-day-lens.md).

## Scope

All presentation. No new persistence, and no change to scheduling, booking, or handoff semantics.

### 1. One AI menu replaces Recommend and Discuss

In `TripPlanningView`'s toolbar, replace the separate **Recommend** (`Icon.recommend`) and **Discuss**
(`Icon.chat`) buttons with a single `Menu` that matches Yes Chef's `RecipeDetailView`:

- Label: **Hand off**, `sparkles.square.filled.on.square` (add an `Icon` case; don't inline the string).
- **Hand off** → `model.startRecommendationHandoff()` (the existing sheet). Retitle the sheet
  "Hand off · Get Recommendations".
- **Paste** → read `UIPasteboard.general.string` on tap and route it into the existing
  recommendation-paste path (`model.recommendationHandoffPaste`). Always enabled. An empty or invalid
  clipboard surfaces the existing warning, never a silent no-op.
- **Ask now** (`sparkles`) → toggles `showingChat`. Checkmark while the inspector is open.
- In the hand-off sheet, **Paste** is enabled whenever the sheet is shown, under the same rule.

**Keep the KNOWN-ISSUES toolbar rule:** every trailing item stays inside the one `ToolbarItemGroup`.
A `Menu` inside the group is fine; a second `ToolbarItem` is not. Verify on iPad with the inspector
open that every item survives.

### 2. Day colors on the map only

- `DayChipBar`: remove the color dot. Keep the "Today" label and its live ring.
- `StopRow`'s sequence badge (`TripItineraryRows.swift:143`): draw it in a neutral style (secondary
  fill), not the day color.
- The map keeps the colors: `TripCanvasMapView`, `TodayDayMapCard`, `JourneyMap`.
- `DayPalette`: reorder or replace so **consecutive days contrast most**. `.pink` sits beside
  `.red` (day 6 and day 1 read as the same red), and `.teal`, `.mint`, and `.green` are close.
  Pick ten hues that are distinct on the Apple Maps base in light and dark mode, and update the
  doc comment to say the color's only job is differentiation.

### 3. Day headers

`SectionHeader` (`TripItineraryDayHeader.swift`):

- Remove the header's **+** button. Each day section ends with an **Add a stop** row (`Icon.add`,
  accent text) that calls the same `model.addToSectionTapped(day:)`. An empty day keeps its row
  and its Add a stop.
- `DayRegionMenu` and `DayTimeZoneMenu`: show a trailing chevron (house rule: anything that opens
  a menu shows one).
- **Time zone shown only when overridden.** `showsDayTimeZoneMenu(forDay:)` already gates on an
  override or two or more regions. Change the label. Overridden: the zone's abbreviation (e.g. `BST`)
  in accent. Inherited: no text, just a compact secondary-colored `clock` glyph, so there is still a
  way to set an override. The menu lists **Trip default (CEST)** first, with a checkmark when the
  day inherits, then the known zones.
- Show the **trip's** time zone once at the trip level: in the itinerary header, under the
  Itinerary/Ideas segment, as secondary text "Times in CEST". Only for dated trips.

### 4. Stop rows

`StopRowAccessory` (`TripItineraryRows.swift:202`):

- Keep the status glyphs (`pinnedReservation`, `BookingStatusGlyph`). They are status, which the
  house rule keeps.
- Remove the pencil buttons. Edit (title and details, or custom stop) moves into a `.contextMenu`
  on the row, together with everything `StopMenu` offers today.
- `StopMenu`'s trigger becomes the **time itself**: a timed stop shows its time (e.g. `9:30`) as
  the menu label; an untimed stop shows its daypart, or a small `clock` glyph when there is none.
  Same menu contents.
- Swipe actions stay as they are (`LifecycleSwipeActions`).

### 5. Hero image collapses on scroll

`TripHeaderImageView` in the column layout (`TripDetailContent.swift:139`): collapse to zero height
once the itinerary list scrolls past its top, and restore at the top. Use
`onScrollGeometryChange`; don't hand-roll offset preference keys. Keep the photo credit with
the image.

## Done when

- One AI menu in the trip toolbar on iPad and iPhone, with all trailing items present while
  the chat inspector is open (iPad screenshot in the PR).
- No color dot on day chips. Sequence badges in the list are neutral. Map pins and routes are
  still per-day colors, and days 1 and 6 are visibly different.
- No **+** in day headers. Add a stop at the end of every day, including empty days.
- A day inheriting the trip time zone shows no zone chip. An overridden day shows the abbreviation
  in accent. The menu's first item is "Trip default (…)". The trip-level line shows for dated trips.
- Stop rows have no pencil. The context menu reaches edit and every `StopMenu` action, and the time
  label opens the time menu.
- The hero image collapses on scroll and returns at the top.
- `scripts/check-drift.sh` green. Before/after iPad screenshots of the canvas in the PR.

## Out of scope

- The hotel row and how days are grouped by stay → [stay-grouped-day-lens.md](stay-grouped-day-lens.md).
- Galavant's own accent color. It is still system blue, which is a foundation-slice decision
  (jon-platform § Visual craft) and is in `open-questions.md`.
