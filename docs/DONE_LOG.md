# Done Log — completed enhancements

Granular enhancement notes that have **fully shipped**, kept for history/context
(not milestone-scoped — see `ROADMAP.md` for those). Companion to
`docs/CURRENT_HANDOFF.md` (what's still open) — this file used to be one long
`docs/BACKLOG.md`; split 2026-07-11 to keep token cost down when an agent reads it
for context.

**Chronological, oldest first** (by the date the work actually shipped, not the
date the entry was originally written).

## Filter reminder above the list (from Jon, 2026-06-12) — DONE

Show active filter settings in small text above the filtered list. Implemented
2026-06-12 (filter summary bar via `safeAreaInset`).

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

## Grow the Itinerary stop detail into a richer screen — in-panel drill-down + first content growth (from Jon, 2026-06-14)

First growth landed 2026-06-15 (M3d follow-up): the detail now opens with a static
thumbnail **map** of the stop's pin, an **Open in Maps** handoff (maps.apple.com
URL), and an **On the Itinerary** section (day + time, or the bucket) via
`stopContext` (nil for a plain pool idea).

The shared read-only `IdeaDetailView` ships as an **in-panel drill-down** (M3d
follow-up): `TripDetailContent` swaps in the detail as an opaque overlay keyed on
`detailIdeaID` (with its own back header) *within the panel itself* (the iPhone
bottom sheet / the iPad right column) rather than presenting a sheet over the map —
the map stays visible the whole time. (Not a nested `NavigationStack`: one inside
the iPad `NavigationSplitView` detail stack made the trip push pop straight back.)
The Trip Ideas list pushes on row tap; the Itinerary keeps row-tap = stop selection
and pushes from a trailing info-circle button (its own hit target, beside the
`StopMenu`).

**Remaining scope** (MKDirections travel time, opening hours, booking — the
reasons to eventually break out of the panel into full-screen) — see
`docs/CURRENT_HANDOFF.md`.

## Ideas list trip-awareness: active-trip capsules + cell trip-badges (from Jon, 2026-06-15) — DONE

Implemented 2026-06-15 on branch `m3e-ideas-trip-awareness`. **(a)** A capsule row
tops the Ideas screen — "All" plus the lifecycle-derived in-play trips
(`Trip.activeCapsules`: every dated + targeted, plus the top-of-backlog someday;
the someday slot approximates "most-recently-touched" by backlog rank since `Trip`
has no touch timestamp). Tapping a trip scopes the pool to that trip's `TripRegion`
lens (reusing `poolFiltered`) and turns each row into a pull/shortlist surface for
*that* trip (the considering/star toggles, mirroring the Add-Ideas sheet, over the
tested `TripIdea` ops); the filter menu's Region submenu hides while a trip is
active. **(b)** In the "All" pool each cell shows a derived `IdeaTripBadge` —
most-actionable across joins (scheduled > upcoming > someday > visited), free ideas
blank; certainty-stage tint (dated blue / targeted orange / someday gray) shared by
the capsule dot. New pure cores `IdeaTripBadge` + `Trip.activeCapsules` with tests.
**Deferred:** the mockup's "match" pill belongs to the next item (his/hers rating +
match), not built here; "Visited" badge drops the year (no visited-date on `Idea`).
Original note below.

*Wants to land soon after the itinerary cleanup.* Two related additions that make the
eternal pool aware of the 2–3 trips actually in play.

**(a) Active-trip capsules.** A row of pills at the top of the Ideas screen = the
in-play trips (Dated + Targeted, plus the most-recently-touched Someday). Tapping a
capsule scopes the pool to **that trip's lens** — the region-scoped pool primed to
pull/rate *for that trip* (PRODUCT.md:17 — pulling happens in the trip's lens; two
Virginia trips are two capsules over one region, so "pull onto which?" is never
ambiguous). Intent: the Ideas screen becomes **dual-purpose** — a launchpad (jump
into an active trip) on top, the firehose below; don't let it drift into "just another
filter bar." Derive the capsule set from the **trip certainty lifecycle**
(recovered-requirements §1: someday→targeted→dated), *not* raw filter MRU (which
lingers stale).

**(b) Cell trip-badges.** Each idea cell shows a **derived** badge of its trip
association — *scheduled* / *on an upcoming trip* / *held in a someday* / *visited* —
projected from the `TripIdea` join records. **No schema change**: there is no
`idea.tripID` (ADR-0007 / PRODUCT.md:56); association is a query over joins. **Free
ideas show no badge** (keep the junk drawer clean). An idea can be on several trips,
so the badge shows the **most-actionable** status: scheduled > upcoming > someday >
visited. Pays off most inside a capsule (trip-scoped) view — the "still free to pull
vs. already committed" signal, same data the not-yet-visited filter uses. Refs:
`TripIdea` join lifecycle, `IdeasScreen` / `PoolMapView`, ADR-0004 (map+filter is the
guide). **Mockup:** `docs/mockups/ideas-trip-awareness.html`.

## His/hers rating rendering redesign + "match" signal (from Jon, 2026-06-15) — DONE

Implemented 2026-06-15 on branch `m3e-ideas-trip-awareness`. The repeated-hearts
render is gone: `InterestView` now draws each planner's level as a **4-segment
filled bar** (Must Do 4 red / Want to Do 3 orange / Could Do 1 yellow), a red
minus for Do Not Do, a "?" for Decide Later, and an empty outline for *pending*
— so Decide Later reads distinct from not-yet-rated. The his/hers row appears
only once **someone** has rated (every party planner then shows, the unrated one
pending), keeping fully-unrated ideas quiet. **Match** (`Interest.standing` /
`isMatch`: ≥2 planners ≥ Want to Do; `passed` = ≥2 Do Not Do) surfaces as a
warm-pink `MatchPill` plus a "Matches only" filter and a "Matches first" sort
(both in the filter menu) that floats matches up and sinks mutual passes — the
worklist. The 5-level scale and rawValues are untouched (ADR-0007 intact). New
pure core in `Interest.swift` with `InterestMatchTests`. Original note below.

*Presentation-only — model is already settled, do NOT touch the scale.* The flames
rating is implemented (per-planner `IdeaInterest`, ADR-0007; 5-level scale Must Do /
Want to Do / Could Do / Do Not Do / Decide Later, recovered-requirements §2) but
renders **illegibly** as repeated hearts ("Jon ❤❤❤ Sam ❤") — you can't tell intensity
from count, and "Decide Later" / not-yet-rated isn't visually distinct from "unrated."
Fix the rendering: show each person's level as a **single legible indicator**, and make
**"Decide Later" distinct from "not yet rated"** (pending). **Keep the 5 levels** — the
scale is load-bearing for shortlist default-ordering and the start-day solver's
weighting (recovered-requirements §2; trip-time-model.md §3 "Must Do loud, Could Do
whisper"); collapsing to yes/no would re-open ADR-0007 and gut the solver.

Additive: surface **"match"** — both planners rated it highly (threshold, e.g. both
≥ Want to Do) — as a derived badge + a sort/filter ("show matches"), turning the pool
into a worklist (matches float up, passed sinks). Match is a **projection of the
flames**, not a separate vote — keeps ADR-0007 intact. Refs: `InterestView`,
`IdeaInterest`, ADR-0007.

## Reveal a selected stop above the iPhone sheet (from Jon, 2026-06-15) — DONE

Implemented 2026-06-15 (M3d follow-up). `MapFraming.reveal` gained a `bottomInset`
(the southern fraction the sheet covers); the canvas feeds it a *measured*
sheet-height ÷ map-height ratio (via `onGeometryChange`, capped at 0.6) and
re-reveals when it changes, so a pin the rising sheet would swallow pans up into
the clear. iPad (inset 0) is unchanged. 3 new MapFraming tests. Original note below.

Selecting a stop pans its pin on screen with the **minimum** move, keeping the
current zoom and not re-centring (`MapFraming.reveal` + `TripCanvasMapView`
`revealStop`, shipped). It pans against the **full** map region, which is exact on
iPad (the detail is a side column, map unobscured) but imperfect on iPhone: the
bottom sheet covers the lower map, so a stop revealed near the bottom edge can land
*behind* the sheet — geometrically on screen, visually hidden. Fix: treat the
sheet-covered height as a **bottom inset** on the reveal box (pan the pin into the
unobscured area above the sheet). Needs the sheet's current height plumbed from
`TripPlanningView` (it owns `sheetDetent`) into the map; system detents
(`.medium`/`.large`) are only approximable, so a measured/inset approach is better
than mapping detents to points. Costs a bit more than the strict minimum pan, by
design (keep the pin out from under the sheet).

## Itinerary panel cleanup: one time vocabulary + drop redundant city (from Jon, 2026-06-15) — DONE

Implemented 2026-06-16 on branch `m3e-ideas-trip-awareness`. **(a) One time
vocabulary** — the itinerary stop's time (the `StopMenu` trailing label, the only
place the vocabularies mixed; the Ideas tab shows just a calendar icon and the
stop detail keeps the verbose `Schedule.display`) now renders by one rule: a
`.timed` stop shows its clock range in **mono + primary** (a hard constraint), a
`.daypart` shows the daypart in secondary (a soft bucket), and a bare-`.day` stop
drops the "Anytime" word for a faint **clock glyph** (`Icon.timeOfDay`) that still
opens the time menu. **(b) Drop the redundant city** — `PlanningRow` gained a
`Subtitle` mode; the Itinerary and Trip Ideas tab pass `.category` (the idea's
kind, e.g. "Museum"), while the Add-Ideas sheet keeps `.region` (the wider pool,
where the city disambiguates). Presentation-only, no schema/test change.
**Deferred (the mockup's unmet half — no data yet):** the subtitle's *neighborhood*
part (we store only locality/city as `regionName` — gated on the search-first
capture work that captures `placemark` sublocality) and the day headers' *area*
label (gated on per-day region stops, deferred in M3). Original note below.

*Leads the design-review batch below; explored with mockups in the 2026-06-15
design session.* The trip itinerary list currently mixes time vocabularies in one
column — meal/daypart anchors (`Morning` / `Lunch` / `Afternoon` / `Anytime`)
sitting next to exact clock ranges (`19:00–21:00`) — which reads as three systems.
Settle on **one spine**: the existing `DayPart` dayparts (Morning / Midday /
Afternoon / Evening) as the default, with an **exact clock time shown only when the
stop is `.timed`**, rendered in **mono** so a pinned time reads as a hard constraint
vs. a soft bucket. Drop `Anytime` as a visible label (it's just "no daypart set").

Separately: every stop row repeats the trip's city ("Tokyo") underneath — pure noise
inside a single-destination trip. **Strip the city subtitle in single-destination
contexts** (itinerary list AND the trip Ideas tab) and put **neighborhood / category**
there instead (signal, not the city we already know). Rule of thumb: show the city
only where it disambiguates (the global pool), hide it where context supplies it
(inside a trip). **Not in scope:** stop drill-down detail content — being revised in
a parallel session, leave it alone. Refs: `Schedule` facade / `DayPart`
(trip-time-model.md), `TripItineraryView`, `TripIdeasView`. **Mockup:**
`docs/mockups/itinerary-cleanup.html`.

## Capture form should be search-first and auto-populated (from Jon, 2026-06-12) — DONE

Implemented 2026-06-16. The New Idea form now **leads with the place search**
(`Section("Place")` at the top); picking a result drives the rest. New schema-side
pure mapping `IdeaKind(pointOfInterestCategoryRawValue:)` (keyed on MapKit's stable
`MKPOICategory*` raw strings so the schema package stays MapKit-free and fully
tested — `IdeaKindTests`; unknown/future categories fall back to nil → Unspecified).
A new SPM module **`GalavantPlaces`** holds the search boundary: a `Place` value
type (the hit + kind/url/phone/address), an injectable `PlaceSearchClient`
(`@Dependency(\.placeSearch)`, MapKit isolated behind it), and the view-facing
`PlaceSearchModel` (query/results/debounce). `IdeaFormModel.setLocation(_:)` fills
name/kind/link **only when still empty** (confirm-and-tweak), refreshing
address/phone/region as facts about the place. New `address`/`phone` columns on
`Idea` (additive migration); the detail view surfaces address + a tappable `tel:`
phone row. Uses the iOS 26 `MKMapItem.location`/`address`/`addressRepresentations`
API (`placemark` deprecated) — no `Contacts`/`CNPostalAddressFormatter` needed.
`PlaceSearchModelTests` overrides the client with a fixture (no MapKit/network) —
the first feature-model test, establishing the package-home pattern for
dependency-backed models (the app target has no test bundle). **Deferred:** the
*neighborhood* subtitle (we store full address, not parsed sublocality — still
gated here). Original note below.

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

## Location search robustness (from Jon, 2026-06-12) — DONE

Fixed 2026-06-16. Root cause: `MKLocalSearchCompleter` biases to the device's
location (Cupertino in the sim) and handles combined "<name> <city>" fragments
poorly, so Copenhagen's Noma never surfaced. Switched `PlaceSearchClient` to
`MKLocalSearch` with a **natural-language query** over a **world-wide region**
(`MKCoordinateRegion(MKMapRect.world)`) — what Maps uses; "Noma Copenhagen" now
resolves. Debounced (300 ms) with in-flight cancellation since `MKLocalSearch` is
throttled, and the last results stay put on throttle/cancel rather than flashing
empty. Bonus: each hit carries its full `MKMapItem`, so picking is synchronous (no
second resolve round-trip). **Note:** a bare 1–2 word name with no city is still
inherently ambiguous worldwide — results sharpen as the user adds the city.
Original note below.

"Noma Copenhagen" returned no results, while "Tivoli Gardens" worked.
Hypothesis: a combined `"<name> <city>"` query underperforms in
`MKLocalSearchCompleter` versus searching `"<name>"` with a **region bias**
(set `completer.region` to the area of interest). Investigate: bias the
completer by the user's current map region (or last-used region), and/or split
trailing city tokens. Also confirm `resultTypes`/`pointOfInterestFilter` aren't
over-narrowing.

## On-device Apple Intelligence for capture enrichment (2026-06-17) — DONE

Shipped as **M4d** (2026-06-17, commit e7b0ebe; see ROADMAP). `PlaceIntelligence`,
an injectable `FoundationModels` client in `GalavantPlaces`, refines the parse
before the Apple Maps match via one guided-generation call (`@Generable` +
`@Guide`): clean name, mined city/region, classified `IdeaKind`, de-marketed
notes; availability-gated with silent fallback to the deterministic parser, and
unit-tested with a fixture. Built as described below. Original note retained for
context.

Use the on-device **Foundation Models** framework (Apple Intelligence; iOS 26+, we
deploy 27) to clean and supplement what the `GalavantCapture` parser extracts —
**replacing** the heuristics M4c added, not stacking on them. Surfaced while
capturing real pages (restaurantalouette.dk, forestis.it): structured-source
priority + pipe-tagline clipping + "confident Apple Maps name overrides a chrome
title" get us far, but they're brittle separator/side rules.

Where it earns its place:
- **Clean place name** from a messy chrome title in one general step — handles both
  "Forestis Dolomites | … Hotel in Brixen" → "Forestis" and "Home — Alouette" →
  "Alouette" without guessing which side of the separator the brand is on.
- **Mine city/locality from free-text description** — the real fix for the "Koan"
  miss (Copenhagen only appears in prose), feeding a far better Apple Maps query
  than a bare name worldwide search.
- **Classify `IdeaKind`** when schema.org `@type` is generic (`LocalBusiness`), and
  **summarize** the page into clean notes.

How to fit it without breaking house style:
- **Guided generation** (`@Generable` structs, `LanguageModelSession`) for typed
  extraction — slots into the value-voting as a high-confidence source, or a
  fallback when JSON-LD/microdata are absent.
- Wrap in an **injectable client** (like `PlaceMatcher`/`PlaceSearchClient`) so the
  deterministic parser stays the fallback and it's testable.
- **Gate on `SystemLanguageModel.availability`** — degrade to today's parser when
  Apple Intelligence is off/unsupported.
- Caveats: runs in the share extension (watch the ~120 MB budget — model is a
  system resource but sessions cost), few-second latency (fine behind the
  "Reading page…" spinner), non-deterministic (hence injectable for tests). New API
  past Claude's training cutoff — check current Foundation Models docs and the
  Xcode `swiftui-*` skills before implementing.

## Itinerary completion model — "now" marker shipped (from Jon, 2026-06-13)

The **"now" marker shipped 2026-06-20** (commit 5353650): a you-are-here divider
on active dated trips (`TripItineraryView` + the `TripPlan` core), so the current
moment's place in the itinerary is shown.

Original context: Jon removed per-stop **Mark Done** from M3c — "no one wants to
mark Done on an itinerary; just assume they did it." Skipped stays (an explicit
negative signal). So completion should be **inferred**, not tapped: once a trip's
day/time has passed, its non-skipped stops are effectively done, and a **"you are
here / now" highlight** should show where the current moment falls in the
itinerary (design TBD at the time).

**Remaining scope** (the inferred completion / trip-level done→visited rollup) —
see `docs/CURRENT_HANDOFF.md`.

## Freeform itinerary stops not tied to an idea (from Jon, 2026-06-13) — DONE

Shipped 2026-06-20 across three slices per **ADR-0010** (commits b3a1015 /
61d900a / d3f4008): (1) schema migration + read-model core — `TripIdea.ideaID`
made optional with `inlineTitle`/`inlineNote` columns, the read-model resolving
each stop into a `StopContent` enum (`.idea` / `.freeform`); (2) stop ops re-keyed
from `Idea.ID` to `TripIdea.ID` so freeform stops work end-to-end; (3) the write
path — per-section "+" and an Add Custom Stop flow. Freeform stops are born
`.scheduled` and carry no coordinate (so no map pin / travel-leg, handled for
free). One record, one itinerary pipeline. See ADR-0010 for the full rationale
(incl. why not a sibling record).

## Hours extraction misses unstructured-markup sites (ADR-0016, 2026-06-23) — DONE

**On-demand ladder DONE (2026-06-23, branch `m6-hours-extractor`).** Shipped the
`HoursExtractor` (`GalavantPlaces/HoursExtractor.swift`) — the on-device LLM
extract-only fallback, mirroring `EvaluationExtractor` (on-device `ModelClient` tier,
strict extract-only prompt, tolerant JSON-object parse degrading to `nil`,
`testValue` → `nil`). Wired into **both** `FieldSupplement` paths via a shared
`resolvedHours(from:)` helper: rung 2 (official-site fetch → `.official`) and the
HITL `applyBrowsedHours` (→ `.unverified`), deterministic structured hours first so a
structured page never pays for a model call. 8 tests (the brewerybhavana-shaped
unstructured fixture + the pure parse degrade). The existing "Find hours" affordance +
HITL browser (`IdeaFormModel`/`IdeaFormView`) now reach unstructured sites with no UI
change.

**Capture-time fallback DONE (2026-06-23).** Two steps shipped together:

1. **Persist deterministic hours at capture** — `CaptureModel.persistCapture` now
   reads `captured.openingHours` (JSON-LD/microdata, already parsed) and writes
   `openingHours`/`hoursProvenance`/`hoursVerifiedAt` onto the `Idea.Draft` (and
   into the merge's `supplemented()` path — fill-blanks-only). Stamped `.official`
   with `now`. The clock is only consulted when there's something to stamp
   (evaluations **or** hours), preserving the original design intent.

2. **LLM fallback deferred to `PlaceEnricher`** — rather than running a second model
   call in the share extension (already at ~120 MB budget from `PlaceIntelligence`),
   the `HoursExtractor` is wired into `PlaceEnricher.enrichIfNeeded` (the app-side
   second hop, M4g) alongside the deterministic pass. Deterministic first; LLM only
   when the parser comes up empty; fill-blanks-only (skipped when the idea already
   has hours from capture). Stamped `.official`. 5 new tests across
   `CaptureModelTests` + `PlaceEnricherTests`.

**Follow-up — the LLM fallback was reaching the model with the wrong text (DONE
2026-06-23, branch `fix/unstructured-hours-excerpt`).** Surfaced on
**das-achental.com/en/es-senz.html**: hours present as free text ("Wednesday –
Saturday 6.30 –11 pm") in a bottom-of-page contact block, but `HoursExtractor`
still came up empty. Root cause was two compounding defects in
`PageParser.textExcerpt`, not the model:
1. **Boilerplate strip was tag-only** (`nav/header/footer/aside`). The site ships
   **zero** semantic landmarks — its whole menu is `<ul><li><a class="single-menu">` —
   so the strip removed nothing and the menu filled the excerpt.
2. **The 1500-char cap then clipped the real content.** The hours sat at char
   offset ~3700, well past the cap; the model only ever saw nav chrome.
Fix: (a) `cleanedBodyText` now also strips by boilerplate class/id and by **link
density** (a block whose visible text is mostly link text is nav, not prose; we
deliberately *don't* strip `class*=menu` — that's a restaurant's food menu); (b) the
single excerpt was split — `textExcerpt` stays a short summary lead (1500, a
deliberate product budget for the summarizer), and a new **uncapped**
`ParsedPage.bodyText` (the full cleaned page) feeds the fact extractors, since
hours/ratings routinely live deep or in a footer. `HoursExtractor` now reads
`bodyText`. (c) Sizing input to a model is the model layer's job, not the parser's:
`OnDeviceModelClient` now **fits the prompt to its own context window**
(`SystemLanguageModel.contextSize` ≈ 4096 tokens — read from the model, not pinned;
reserve system + output, char-budget the rest with a safety margin), so a whole-page
extract or a long chat degrades to a shorter prompt instead of throwing
`contextSizeExceeded`. 6 tests (`PageParserTests` link-density + footer-hours,
`HoursExtractorTests` live-path-reads-bodyText, `OnDeviceFitTests` fit math).
**Still structured-data-blind only if a site renders hours purely client-side**
(no hours in the fetched DOM at all) — that remains the HITL-browser's job.

## Capture never persists opening hours at all (found 2026-06-23) — DONE

Fixed as part of the "Unstructured-hours capture fallback" above (2026-06-23).
`CaptureModel.persistCapture` now writes the deterministic hours from
`captured.openingHours` onto the idea at save time. See the entry above for full
details.

## ADR-0033 Slice 4 — floating-untimed-stops UI — DONE (2026-07-10)

Shipped 2026-07-10. The stop clock-time editor (`StopTimeSheet` + `Destination.stopTime`,
pre-filled from `Schedule.suggestedTime`), the menu-based **"Move Earlier / Later in
Day"** reorder (`reorderDayStops`, bare-Anytime-only, "earlier" disabled at the first-timed
boundary), and destination-day time seeding on Move-to-Day (`moveToDay`) all landed on
`StopMenu` / `TripPlanningModel+Scheduling`. The §2 "before the first timed stop"
limitation was kept, not lifted (a daypart is still the way to seat a stop ahead of the
day's first timed stop) — see the ADR-0033 §2 "Slice 4 resolution" note for why (it would
have re-seated dogfooded Anytime stops). Original scope below.

ADR-0033's functional core (a per-stop intra-day `dayRank`; anchored interleave of
"Anytime" stops between timed ones; a pure `Schedule.suggestedTime(after:before:)`)
shipped and is unit-tested. The **UI is the remaining slice**, and it's net-new, not
a wiring-up:

1. **Stop clock-time editor.** There is *no* way to set an exact time on a stop today
   — `StopMenu` offers only Anytime + dayparts + Move-to-Day; `.timed` stops exist only
   in demo fixtures. Add a "Set time…" affordance that opens an hour-minute editor
   (clone the stay editor's `timeRow`/`DatePicker` in `TripPlanningSheets`), **pre-filled
   from `Schedule.suggestedTime`** using the stop's ordered-day neighbors. Also pre-fill
   it on a cross-day move (ADR-0030) so the new day's neighbors seed the time.
2. **Non-drag intra-day reorder** writing `dayRank` via `TripIdea.reorderDayStops`. Drag
   is blocked — the Xcode 27 beta 1 `List` drop-timeout (KNOWN-ISSUES, and the
   cross-day-drag entry in `docs/CURRENT_HANDOFF.md`), *and* the itinerary row stream is
   heterogeneous (stops + connectors + now-marker + check rows), so `.onMove` needs the
   `ScrollView`/`LazyVStack` rebuild noted there. Until then, a menu-based "Move
   earlier / later in day" on `StopMenu` is the tractable affordance (mirrors the
   existing Move-to-Day idiom).

`swiftui-specialist` checkpoint; app target is untestable so verify on the iPad Pro
13-inch sim. Note the anchor limitation from ADR-0033 §2: an Anytime stop can't yet be
placed *before* the day's first timed stop via order alone — give it a daypart, or let
the reorder UI teach the anchor a "before-first" case.

## Sync status indicator: adopt the CloudSyncKit `.downloading` state (jon-platform ADR-0028, 2026-07-10) — DONE

**DONE 2026-07-10** (same session as the CloudSyncKit fix; not yet committed — Jon does
the git dance). Both app-side sites updated to match Yes Chef: `SyncHealthModel.refresh()`
now feeds `isFetchingChanges: isEngineRunning && syncEngine.isFetchingChanges`, and
`SyncStatusSection`'s three switches handle `.downloading` (blue dot, "Downloading changes
from iCloud" detail line, first-large-sync-takes-a-while explanation). Build succeeds
(`iPad Pro 13-inch (M5)` sim, `-skipMacroValidation`); `swiftlint --strict` clean. The
original note is kept below for context.

**Origin:** Yes Chef's two-device dogfood found the Settings sync row lying "Up to
date" while a fresh device was still pulling a large library *down* from CloudKit
(nothing pending to upload, so the reducer flipped green the instant the first batch
landed — a throttled bulk initial sync drip-feeds tens of thousands of rows over
hours). The fix landed in **CloudSyncKit** (the shared package, referenced here by
local path `../../jon-platform/packages/CloudSyncKit`), so Galavant inherits the
reducer change automatically — **and inherits a compile break until the app-side
switches handle the new case.**

**What changed in CloudSyncKit (`SyncHealth.swift`):**
- `SyncHealth` gained a boolean input `isFetchingChanges` (defaulted `false`, so the
  `SyncHealth(...)` init call still compiles unchanged).
- `SyncDisplayStatus` gained a new case **`.downloading`** — pull-in-flight, nothing
  left to push. This is what makes the exhaustive `switch`es over `SyncDisplayStatus`
  **fail to build** until updated.
- Reducer gates `.downloading` *after* the upload-pending check (an upload carries a
  count and is the more useful thing to show; both are honest "in progress" states).
  `.downloading.summary == "Syncing…"` (same glanceable text as `.syncing`).

**Galavant app-side changes to mirror (parallel to Yes Chef's, same file names):**
1. **`Galavant/Settings/SyncHealthModel.swift`** — in `refresh()`, feed the new input:
   `isFetchingChanges: isEngineRunning && syncEngine.isFetchingChanges` into the
   `SyncHealth(...)` init (line ~59). No view-wiring change needed — `SettingsScreen`'s
   existing `.onChange(of: syncHealth.isSynchronizing)` already covers fetch toggles
   (`isSynchronizing == isSendingChanges || isFetchingChanges`).
2. **`Galavant/Settings/SyncStatusSection.swift`** — add `.downloading` to the three
   exhaustive switches: the dot color (`case .syncing, .downloading: .blue`), the
   detail line (e.g. `"Downloading changes from iCloud"`), and the explanation footer
   (a "first sync of a large library can take a while — keep on Wi-Fi and power" note
   reads well here). These are the compile-forcing sites.

**Scope note (don't chase it):** there is **no public rate-limit/backoff signal** —
SQLiteData swallows the throttle `CKError`s internally (SyncEngine.swift ~1794/1830),
so the row can't say "paused by iCloud, will resume" and may briefly flash "Up to
date" *between* throttled fetch batches. Accepted limitation, same as Yes Chef; a
truthful pause state would need an upstream SQLiteData change. See
`yes-chef/docs/decisions/ADR-0028-*.md` for the full write-up.

## ADR-0008 logical-uniqueness convergence — sync dedup hardening — DONE

Shipped 2026-08-12 (PR #20, branch `codex/adr-0008-logical-uniqueness-dedup`).
Closes the open half of ADR-0008: SQLiteData's CloudKit sync has no unique indexes, so
two devices editing offline can each insert a row for the same logical key, syncing into
a logical duplicate. Added:

- **`GalavantSchema/LogicalUniqueness.swift`** — pure `Sequence.convergingByKey`, generic
  over `Identifiable where ID == UUID`, keeps the lowest-`id` survivor (a total, stable
  order so every device independently converges), returns `(survivors, losers)`. These
  tables carry only `id`, so lowest-UUID *is* the order — no new synced column (contrast
  Yes Chef's recipe convergence, which orders by `dateCreated` → `id`).
- **IdeaInterest** — his/hers reads collapse duplicates **non-mutatingly** (a duplicated
  opinion no longer double-counts into the match projection); `IdeaInterest.set` does the
  deterministic pick + loser-delete on the owning write, merging any distinct loser notes.
- **IdeaTag / TripRegion** — cleanup on the owning write path; reads were already `Set`-safe.
- **`TravelParty.ensureDefault`** — prefers a populated party over an empty first-run stray,
  repoints all 7 direct child tables (Idea/Planner/MapRegion/Tag/TravelProfile/Trip/
  IdeaEvaluation) to the survivor **before** deleting losers, and fast-paths the common
  single-party case.

Invariants held: read paths never delete (only owning writes do); survivor is deterministic
and order-independent; no new synced columns. 9 seeded-duplicate/convergence tests in
`GalavantSchemaTests`, run with `swift test --filter "LogicalUniqueness|Convergence"` to
avoid the FoundationModels host-gap abort. Reference: Yes Chef's shipped
`RecipeRepository+Import.swift` convergence + jon-platform `persistence-and-sync.md` law 3.
Follow-ups tracked in `CURRENT_HANDOFF.md`: real two-device dogfooding of the party merge;
`Planner.create` planner-level dedup for the two-populated-parties edge.

## M9 recommendation-handoff substrate + evaluation-workspace core (ADR-0036 S1/S2, ADR-0037 P1–P2) — DONE

The external-LLM handoff substrate and the settled core of the evaluation workspace shipped.

- **Handoff seam + paste door (ADR-0036 S1).** Device-local handoff record; tokenized brief;
  strict-JSON candidate decode (HoursExtractor pattern) → row-grain review → commit as
  `.considering` `TripIdea` (rationale in `inlineNote`); `GV-CONTRACT` staleness marker; in-app
  Copy-brief / Paste-result door.
- **Resolution ops + choose-one (ADR-0036 S2).** Use This Place wired to the capture merge/dedup
  (ADR-0019); "choose one" → alternatives ring (ADR-0035).
- **Evaluation workspace core (ADR-0037 P1–P2).** Three-surface inbox with the candidate rail +
  always-one-selected traversal (tested pure core in `GalavantSchema`), three-layer map, the
  Use This Place resolve (dedup-keyed `Idea`, AI rationale preserved on the trip stop), and
  Save-to-Ideas / Add-to-itinerary / dismiss-with-undo, plus resolve-time duplicate reconcile
  (default merge, keep-both).

Still **current, not done** (see `CURRENT_HANDOFF.md`): the layout was reworked into a dedicated
**evaluation cockpit** — Evaluate promoted to a top-level section (Slice 1) plus the iPad
browser/map/candidate-strip cockpit with Add-to-Day placement, prominent map pins, direct
search-resolve, toolbar Connect, Site badge, Google search, opt-in consent auto-accept, and
⌘-number section shortcuts (Slice 2) — built and in **PR #36** (supersedes the P3/P4 arrangement
from #31/#32). The **lift** (ADR-0036 S3) is also built and in **PR #35** (`LLMHandoffKit` created;
Galavant consumes via an `@_exported` shim, behavior-neutral; yes-chef adoption is the open
follow-up). Both graduate to a full DONE entry here once merged. Remaining M9 layout work: Choose
One day-anchoring, Slice 3 (dossier flyover that covers siblings), Slice 4 (iPhone map-first
layout).

## App unit-test bundle + IdeasListModel filtered-delete regression (Codex review 2026-06-16) — DONE

The app target had no unit-test bundle, so `IdeasListModel` behavior had no automated regression
guard — the long-standing blocker on the filtered swipe-delete test from the 2026-06-16 alignment
review. Shipped 2026-08-16 (PR #46, `feat/app-unit-test-infra`):

- **Host-backed `GalavantTests` Xcode target**, generated from `project.yml` (both `project.yml` and
  the regenerated `project.pbxproj` committed together, per the XcodeGen workflow). Links only
  `DependenciesTestSupport` directly; `GalavantSchema`, `SQLiteData`, and `Dependencies` inherit
  through the `Galavant` test host (`TEST_HOST`/`BUNDLE_LOADER`) to avoid duplicate SQLiteData
  symbols in Xcode's dynamic test overlay. Added to the `Galavant` scheme's Test action.
- **`IdeasListDeleteTests`** runs on an in-memory `bootstrapDatabase()` (test context → sync
  `.disabled`, no CloudKit). It seeds two disjoint regions with one idea each, filters to region B,
  deletes displayed index 0 via the real `deleteIdeas(filteredIdeas, at:)` path, and asserts the
  region-B idea is deleted while the globally-first region-A idea survives — the exact structural
  bug (indexing the global name-ordered list instead of the displayed slice) the earlier fix closed.

Verification: `xcodebuild test -only-testing:GalavantTests/IdeasListDeleteTests` passed;
`swift test --package-path GalavantLibrary` still green (the pre-existing `GalavantUITests-Runner`
bootstrap crash is unrelated). Now that the bundle exists, it's the seam to pull more
`IdeasListModel` behavior under test.

## Today execution — complete / skip / defer / tap-to-detail (ADR-0039) — DONE

Turned the Today iPhone cockpit from a read-only projection into a light execution
surface. Shipped 2026-08-16 (PR pending, `feat/today-execution`); implements
ADR-0039 (supersedes ADR-0038's read-only restraint for Today — Journey stays
read-only). Fixes the inert "Anytime day" where the clock can't advance NEXT.

- **Overlay schema (Phase 1).** Two nullable, mutually-exclusive columns on
  `TripIdea` — `completedAt` / `skippedAt` — with a total in-memory `StopOutcome`
  facade (`.pending` / `.done(Date)` / `.skipped`) and `isPending`. The stop stays
  `.scheduled`; execution is a lens over the plan, not a status change. Additive
  nullable migration, rides SQLite→CloudKit like all domain state (ADR-0003).
- **DB ops (Phase 2).** `complete` / `uncomplete` / `skip` / `unskip` statics on
  `TripIdea`, each enforcing mutual exclusion in the DB layer. Defer reuses existing
  scheduling: `deferStopToTomorrow` = `schedule(.day(day+1))`; `deferStopToLaterToday`
  = new `TripIdea.moveToEndOfDay` (max-`dayRank`+1, propagated across an alternative
  ring).
- **Projection (Phase 3).** NEXT is the first *pending* upcoming stop (so checking one
  off advances it); `TodayProjection.Progress(done, total)` with skipped excluded from
  the denominator; collapse driven by outcome for stops (`.done(count:)` /
  `.skipped(count:)` summaries — replacing the old clock-based `.earlierToday`) layered
  on the Phase 0 past-ness divider for boundaries/connectors. Preview stays a faithful
  full-plan read.
- **Model wrappers (Phase 4).** Thin `@MainActor` async methods on `TripPlanningModel`
  over the Phase-2 ops, timestamp from `@Dependency(\.date)`, `@FetchAll` refresh (no
  manual state).
- **View (Phase 5).** Live-gated affordances: header progress count, NEXT-hero "Done"
  button, per-row check circle + `⋯` menu (Skip / Do later today / Do tomorrow, last
  hidden on the final day), "Done · N" / "Skipped · M" collapse rows, per-leg Directions
  on connectors (current leg prominent, trivial <1min walk suppressed, orphaned-origin
  legs labelled "From X"), and a tap-to-detail sheet on stops with an idea (live and
  preview). Also folds in the Phase 0 transfer-day REMAINING fix (already on `main`, #50)
  and the ADR-0039 addendum (Directions belong to the leg, not the NEXT hero).
- **Reversible collapse.** The "Done · N" / "Skipped · M" summaries are **expandable
  disclosures** — `TodayProjection` surfaces `doneStops` / `skippedStops` next to the
  counts, and expanding one (`TodayTimeline.outcomeDisclosure`) reveals its stops as full
  rows that keep their check-circle and `⋯` menu (uncheck / "Undo done" / "Unskip"). Undo
  stays reachable while the default timeline stays compact — closing the review's one gap.

Verification: `swift test --package-path GalavantLibrary` green (380 tests, incl. four
new outcome/ops/projection tests); `xcodebuild build -scheme Galavant` clean on iPhone 17
Pro / iOS 27.
