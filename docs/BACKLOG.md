# Backlog — granular enhancements

Not milestone-scoped (see ROADMAP.md for those). Running list of refinements
noted in passing, with enough context to act on cold.

## Capture form should be search-first and auto-populated (from Jon, 2026-06-12)

The New Idea form currently leads with Name, then a Location section midway
down. It should **invert**: location search at the *top*, driving the form. You
search a place, pick it, and the rest fills in from what MapKit returns:

- **Kind** ← `MKMapItem.pointOfInterestCategory` mapped to `IdeaKind`
  (e.g. `.restaurant` → `.food`, `.museum` → `.museum`, `.hotel` → `.stay`).
  Build the category→kind table; fall back to unspecified.
- **Link** ← `MKMapItem.url` (the place's website).
- **Address / phone** ← `MKMapItem.placemark` / `phoneNumber` (we currently
  only keep locality as `regionName`; capture more).
- Name is already auto-filled; the rest of the form becomes confirm-and-tweak.

This is the on-device cousin of the V1 server enrichment (scraping-enrichment.md)
— MKMapItem is itself a rich enrichment source we're underusing. Pull forward
into M2 capture polish or fold into M4.

## Location search robustness (from Jon, 2026-06-12)

"Noma Copenhagen" returned no results, while "Tivoli Gardens" worked.
Hypothesis: a combined `"<name> <city>"` query underperforms in
`MKLocalSearchCompleter` versus searching `"<name>"` with a **region bias**
(set `completer.region` to the area of interest). Investigate: bias the
completer by the user's current map region (or last-used region), and/or split
trailing city tokens. Also confirm `resultTypes`/`pointOfInterestFilter` aren't
over-narrowing.

## Planner identity feels fly-by-night (from Jon, 2026-06-12)

The name-only "Who are you?" prompt feels flimsy; Jon wants a stronger key
(email on file, collision-resistant). Resolution direction recorded in
**ADR-0008 → "Future: back planner identity with the CloudKit participant"**:
derive identity from the accepting Apple ID (unique key + name/email when
consented), `displayName` as editable override. Blocked on the M5 real-device
share-accept flow. Cheap interim option: optional typed `email`/subtitle on
`Planner` for picker disambiguation.

## Consolidate management UIs into a settings/"You" area (from Jon, 2026-06-12)

Tag and Region management currently hang off the filter menu (Manage Tags… /
Manage Regions…). That's a temporary home — these (plus planner identity/
switching and sync health) should migrate into a dedicated settings or "You"
nav section, not be buried in the filter. Punted for now; tracked here. Likely
lands when the third nav section ("You"/Account) is built (M5-ish).

## Multi-select tag assignment on Ideas (from Jon, 2026-06-13)

The data model already supports many tags per idea (IdeaTag join), but the form
adds them **one at a time** (type-and-add with autocomplete). Jon wants a
**multi-select tag picker** (confirmed 2026-06-13): a scrollable list of all
existing tags with checkmarks, toggling several on/off at once. **A dedicated
screen is acceptable** (push from the form's Tags section → tag-picker screen →
back). Keep the type-to-create-new-tag path available there too. The current
one-at-a-time add stays as the inline quick path; this is the "manage many"
surface. Likely reuses TagManagerView's list shell.

## Export itinerary to Apple Calendar / iCal (from Jon, 2026-06-13)

Once a trip is **dated**, let the app populate a calendar with its scheduled
stops via **EventKit** (`EKEvent`s in a dedicated "Galavant: <trip>" calendar,
or `.ics` export for sharing). The M3c data model is already shaped for this:
`Trip.date(forDay:)` derives the calendar date for each day number, and the
`Schedule` facade gives the time — `.timed` → exact `EKEvent` start/end,
`.daypart` → an all-day-ish event anchored at `DayPart.sortHour` (the
representative hour we already sort by), `.day` → all-day event. Undated trips
have nothing to export (day-relative only). Considerations: re-export should
reconcile (update/delete) rather than duplicate; needs the Calendars privacy
permission; likely a per-trip "Add to Calendar" action. Bigger than a one-liner
— a small feature, post-M3 (fits the M5 polish/integration band).

## Booked reservations as absolute, pinned stops (from Jon, 2026-06-13)

A confirmed reservation (OpenTable, hotel, timed entry) is an absolute fact —
nailed to a calendar date, must **not** slide when the trip's start date moves,
unlike a day-relative *planned* stop. M3c trimmed V2's `.exact(Date,…)` from
`Schedule` (day-relative is deliberate — trip-time-model.md §2), but did **not**
preclude this. Fix is additive: an optional `TripIdea.pinnedDate: Date?` plus
booking metadata (confirmation #, booking URL, party size, booked-vs-planned)
that locks the stop to its date and re-derives `dayNumber` if the start slides.
Land with **M4 capture** (when a share/OpenTable import creates one); pairs with
the "reservable-from" booking-window work. Full rationale + decision in
**docs/trip-time-model.md §4**.

## Trip header image — "romance" (from Jon, 2026-06-14)

The trip screen looks stale; Jon wants a **selectable header image** so a trip
*feels* like its place ("feel like Copenhagen"). Worth the vertical space.
Precedent: V1/V2 GalavantLibrary `UnsplashSearch` (already a tested SPM module —
docs/MINING.md M5 row) let you pick from an image service. Plan: a per-trip
image (search Unsplash by destination/region name, or pick from Photos), shown
as a large header on the planning screen behind the title. Considerations:
needs an Unsplash API key (confirm the service/free tier still exists, else
swap source) + attribution; store the **choice** (URL/asset id + author) on
`Trip` and CloudKit-sync it; cache the bitmap locally (don't sync blobs). This
is the romance/polish pass — ROADMAP already lists "Unsplash header images" under
M5; this elevates it. A focused feature, not a quick tweak — do it as its own
slice.

## AI assistant / chat (from Jon, 2026-06-13)

A larger future theme, not yet milestone-scoped: an in-app conversational
assistant (Claude API — see CLAUDE.md model guidance) layered over the pool +
trips. Plausible jobs, roughly in value order: **capture/enrichment** ("add the
restaurant from this link", parse a pasted blog list into ideas — overlaps the
M4 scraping pipeline), **planning help** ("draft a 3-day Copenhagen itinerary
from my shortlist", "what's near Tivoli I've saved?"), and **Q&A over the pool**
("which Denmark food ideas haven't we visited?"). Wants a real design pass:
where it runs, what context/tools it gets (read the SQLite pool? call the
schedule ops?), cost, and the two-person-household privacy posture. Park here as
a direction; revisit after the core loop (M3/M4) is solid.

## Drag itinerary stops between days / out of the bucket (from Jon, 2026-06-13/14)

M3c places/reorders stops via a "Move to Day"/"Set Day" menu + the Add-Stop
sheet. Jon wants stops **draggable across day sections** directly — *and* (added
2026-06-14) **dragging items out of the "To Be Scheduled" bucket onto a day**.
Both are the same gesture: drop target → day number → `TripIdea.schedule(_.onDay(n))`
(or `scheduleUnplaced` to drop back into the bucket). Needs cross-section drag
(the M3b `reorderable()`/`reorderContainer` is single-collection). Within-day
reordering is moot (stops auto-sort by time), so this is purely "drop onto
another day / the bucket." Fast-follow; the menus cover the function until then.

## Grow the Itinerary stop detail into a richer screen (from Jon, 2026-06-14)

The shared read-only `IdeaDetailView` ships as an **in-panel drill-down** (M3d
follow-up): `TripDetailContent` swaps in the detail as an opaque overlay keyed on
`detailIdeaID` (with its own back header) *within the panel itself* (the iPhone
bottom sheet / the iPad right column) rather than presenting a sheet over the map —
the map stays visible the whole time. (Not a nested `NavigationStack`: one inside
the iPad `NavigationSplitView` detail stack made the trip push pop straight back.)
The
Trip Ideas list pushes on row tap; the Itinerary keeps row-tap = stop selection
and pushes from a trailing info-circle button (its own hit target, beside the
`StopMenu`). Deferred follow-up: grow the **Itinerary** stop detail with richer
per-stop context (map of the stop, MKDirections/travel time, opening hours,
booking) — at which point it may want to break out of the panel into a
full-screen presentation. Revisit once that content exists.

## Itinerary completion model: assume-done + a "now" marker (from Jon, 2026-06-13)

Jon removed per-stop **Mark Done** from M3c — "no one wants to mark Done on an
itinerary; just assume they did it." Skipped stays (an explicit negative signal).
So completion should be **inferred**, not tapped: once a trip's day/time has
passed, its non-skipped stops are effectively done, and a **"you are here / now"
highlight** should show where the current moment falls in the itinerary (design
TBD — Jon unsure how yet). Consequence for the **done→visited** feedback loop
(ADR-0004): it moves from a per-stop action to a **trip-level rollup** — when a
trip is past/marked complete, flip its scheduled ideas' `visited`. The
`TripIdea.markDone` op + test stay (the mechanism); only the UI trigger changes.
Design item; pairs with weather/“now” work on the trip canvas.

## Freeform itinerary stops not tied to an idea (from Jon, 2026-06-13)

Some itinerary entries aren't pool ideas — "lunch break", "train to Aarhus",
"check in". Today a stop **is** a `TripIdea` (requires `ideaID`). Options: make
`TripIdea.ideaID` optional + carry an inline title, or a sibling freeform-stop
record sharing the schedule columns. Touches the ADR-0004 "a stop is a pulled
idea" assumption — wants a short ADR/design note before building. Schedule
facade + day model already handle the timing; only the "what is this stop"
identity changes.

## Accommodations (from Jon, 2026-06-13)

Not yet modeled. Hotels/stays behave unlike point stops: they **span nights**,
should appear across the days they cover (or as a persistent day-header chip),
and drive each day's "home base" region (ties into the deferred per-day region
stops). Likely its own record (a stay with check-in/out day numbers) rather than
a `.timed` stop. Own design pass — sibling to per-day regions and the map canvas.

## Portfolio extraction seams: parser engine + image processing (from Jon, 2026-06-14)

Two capabilities coming up have a life beyond Galavant (Jon's wider app
portfolio, e.g. a future recipe manager): **web capture/parsing** (M4) and
**image storage tools** (M2 images). Decision: **isolate now, extract later** —
do *not* stand up a shared package against a single consumer (premature
extraction calcifies the wrong API). The expensive mistake is *entanglement*,
not late extraction; so build both as cleanly-isolated targets in the local SPM
package with strict boundaries, and lift to a neutrally-named shared package only
when a **second real app** needs them and both consumers' requirements are
visible (the "reason" CLAUDE.md requires for a new package).

Boundary discipline to enforce while building:

- **Parser engine = `HTML/text → generic structured struct`.** The portable unit
  is the *pure transform* (schema.org/JSON-LD/OpenGraph → normalized result), not
  "in-app browser." The browser is just one *source* of HTML (share extension and
  server fetch are others). Engine must never import SwiftUI/CloudKit and never
  see `Idea`/`Trip` — domain mapping (generic result → `Idea`) stays in the app.
  This also makes it unit-testable with zero browser/network. Aligns with the M4
  enrichment pipeline (docs/scraping-enrichment.md).
- **Image tools = split processing from storage.** Resize/compress/thumbnail are
  pure functions over `Data`/images — maximally portable, the clean extraction
  candidate. *Storage* ("dedicated table, CloudKit-synced, no S3" — ROADMAP M2 +
  ADR-0001) is stack-specific; it travels only if the other app also uses
  SQLiteData+CloudKit. Keep processing free of any persistence import.
- **Naming (ADR-0006):** a portfolio library needs a *neutral* name — no app
  domain in it. V2's `GalavantLibrary` was within-app and Galavant-named; that
  pattern is wrong for a cross-app package. Decide the name when the second
  consumer is real, not now.

No code action yet — this is intent to honor when M2 images and M4 capture get
built, so the eventual extraction is a rename-and-move rather than surgery.

## Icon enum — central SF Symbol vocabulary (from Jon, 2026-06-14) — DONE

Implemented 2026-06-14 (`Galavant/Design/Icon.swift`, own commit). Swept the
chrome literals across the 17 listed files to `Icon.x.label(…)` / `.image` /
`.systemName`. Deliberately left as-is: domain-enum `systemImage` properties
(`IdeaKind`, `DayPart`, `IdeasScreen.Mode`), interpolated generic helpers
(`AddIdeasSheet.addToggle`, the off-state filter glyph), and fill/outline toggle
pairs where the lit glyph has no role case (`star`/`star.fill`,
`calendar.badge.checkmark`, `heart`/`heart.fill`). Original draft retained below
for reference.

Adopt a single semantic icon enum (V2 had one; reviewed 2026-06-14). Today the
app has ~65 `Image(systemName:)`/`systemImage:` call sites across 26 distinct
stringly-typed symbols; a typo renders *blank*, never fails to compile. The enum
names each symbol by **role** (`.edit`, not `"pencil"`) so a glyph swaps in one
place and call sites read as intent. Lighter/stricter than V2's (which only got
partial adoption): no dependency, role-named, enforce "no raw `systemName:` in
chrome" in review. Domain enums (`IdeaKind`, `DayPart`) keep their own
`systemImage` — this is for shared UI affordances only.

**Do this as its own commit, after M3d is committed** (don't fold into M3d).
Lives in `Galavant/Design/Icon.swift` (new dir). Ready-to-go draft (every symbol
below is already in use, so all are known-valid):

```swift
import SwiftUI

/// The app's icon vocabulary: every SF Symbol used in chrome/actions, named by
/// *role* not glyph, so a symbol swaps in one place and call sites read as intent
/// (`Icon.edit`, not `"pencil"`). A mistyped symbol can't reach a view — the case
/// is the only spelling. Domain enums (`IdeaKind`, `DayPart`) keep their own
/// `systemImage`; this is for shared affordances.
enum Icon {
  // Create / edit / destroy
  case add            // primary add (toolbar / list)
  case addInline      // inline "create this" affordance
  case defineRegion   // create a map region
  case edit
  case delete         // permanently remove
  case remove         // take out of a set (e.g. a tag)
  case skip           // mark a stop skipped
  case revert         // move back / undo a placement

  // Status / controls
  case checkmark      // selected / confirmed
  case disclosure     // row chevron
  case filterActive   // filter control, engaged
  case manage         // manage / adjust (regions, tags)
  case sidebar

  // Scheduling
  case calendar       // generic / "nothing scheduled"
  case schedule       // place a stop on a day
  case unschedule     // pull a stop off its day
  case toBeScheduled  // committed but dayless

  // Places
  case map
  case location       // a stop/idea that has coordinates

  // Domains / sections
  case trips
  case ideas
  case shortlist
  case interest
  case tag
  case travelParty
  case emptyPool      // empty idea pool

  var systemName: String {
    switch self {
    case .add: "plus"
    case .addInline: "plus.circle"
    case .defineRegion: "plus.viewfinder"
    case .edit: "pencil"
    case .delete: "trash"
    case .remove: "minus.circle.fill"
    case .skip: "xmark.circle"
    case .revert: "arrow.uturn.backward"
    case .checkmark: "checkmark"
    case .disclosure: "chevron.right"
    case .filterActive: "line.3.horizontal.decrease.circle.fill"
    case .manage: "slider.horizontal.3"
    case .sidebar: "sidebar.left"
    case .calendar: "calendar"
    case .schedule: "calendar.badge.plus"
    case .unschedule: "calendar.badge.minus"
    case .toBeScheduled: "calendar.badge.clock"
    case .map: "map"
    case .location: "mappin.circle.fill"
    case .trips: "suitcase"
    case .ideas: "lightbulb"
    case .shortlist: "star"
    case .interest: "heart.fill"
    case .tag: "tag"
    case .travelParty: "person.2"
    case .emptyPool: "tray"
    }
  }

  /// The raw glyph (icon-only buttons, decorative images).
  var image: Image { Image(systemName: systemName) }

  /// A titled label — the common `Label("…", systemImage:)` shape.
  func label(_ title: LocalizedStringKey) -> Label<Text, Image> {
    Label(title, systemImage: systemName)
  }
}
```

Sweep when applying: replace the literals in these files —
`AppContainer`, `AppScreen`, `IdeaFormView`, `IdeasScreen`, `IdentityView`,
`InterestView`, `PoolMapView`, `RegionManagerView`, `StopMenu`, `TagManagerView`,
`TripCanvasMapView`, `TripDetailContent`, `TripFormView`, `TripIdeasView`,
`TripItineraryView`, `TripPlanningSheets`, `TripsScreen` — using
`Icon.x.label("…")`, `Icon.x.image`, or `Button("…", systemImage: Icon.x.systemName)`.
NB: don't name it so it collides with SwiftUI's `Label<Title, Icon>` generic —
keep the convenience on the enum (above), don't add a `Label where Icon == Image`
extension. Optional follow-on: if/when the app gets a unit-test target (or this
moves to a package module), add a test asserting `UIImage(systemName:) != nil`
for every case to catch future typos at test time.

## Filter reminder above the list (from Jon, 2026-06-12) — DONE

Show active filter settings in small text above the filtered list. Implemented
2026-06-12 (filter summary bar via `safeAreaInset`).
