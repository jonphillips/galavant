# Handoff: Journey — the iPad anticipation/comprehension surface

Status: Draft (ready to dispatch). Next surface in the M10 arc after Today
(ADR-0038 §8: "Today first, dogfood, then Journey" — Today shipped on
`feat/today-execution`, 2026-08-16).

Summary: Build **Journey**, the iPad read-only view that answers "make me want to
*go* on this trip" — the shape, rhythm, geography, and character of the whole trip
at a glance: a per-day story, accommodation bands spanning their nights, the journey
map, and a trip summary. Coarse per-day weather appears only near departure; the
weather-free card is the primary design. **Journey never edits and never persists.**

Implements: ADR-0038 (`docs/decisions/0038-journey-today-projections-and-weather.md`)
— the **Journey** half. Read it first; it carries the *why* and the restraints. The
**Today** half already shipped and is the working template for the pure-projection +
thin-SwiftUI + weather-foundation pattern this brief reuses.

Depends on (all shipped, reuse — do NOT rebuild):
- `TripPlan` read model (`GalavantSchema/TripPlan.swift`) — the single source of truth.
- The weather foundation: `WeatherAnchor` + `WeatherRequestPolicy` (pure, `GalavantSchema`)
  and the app-layer `@Dependency(\.weatherClient)` → `WeatherSummary`
  (`Galavant/Weather/`), device-verified in Today. `WeatherAttributionLink` exists.
- `TodayProjection` (`GalavantSchema/TodayProjection.swift`) — the reference for how to
  build a tested projection value and how weather anchors resolve.

---

## Shared context (read first)

Repo: galavant (V3) at `~/code/galavant/galavant`. Household iOS app, SwiftUI,
SQLiteData+CloudKit, **no server**, Point-Free style **without TCA**. Read `AGENTS.md`
+ `CLAUDE.md` first. Conventions that bite:

- **Branch + PR workflow:** never push to `main`. Feature branch off `main`
  (suggest `feat/ipad-journey`), open a PR. **No git worktrees** — a plain checkout is
  correct.
- **XcodeGen-managed project:** `project.yml` is source of truth, `project.pbxproj` is
  generated AND tracked. Run `xcodegen generate` **only if you add/remove a file in the
  _app_ target**, then commit BOTH. Package files/test files need no xcodegen. This work
  will add app files (a Journey view + model) → regenerate + commit both.
- App builds with `-skipMacroValidation` (macro trust may need re-approval in Xcode).
  Verify with `swift test --package-path GalavantLibrary` (schema/core; runs headless —
  the FM-linked app test bundles are excluded by that package path) **and**
  `xcodebuild build -scheme Galavant -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
  -skipMacroValidation`. Don't claim green if you only built. **Review on an iPad
  simulator** (install/launch on **iPad Pro 13-inch (M5)** — Jon's preferred review sim).
- **No new synced record, no migration, no CloudKit change.** Journey is a projection.
  If a fact needs to survive it already lives on `Trip`/`TripIdea`/`TripStay`/
  `TripDayRegion` and is *reused*.
- Match surrounding comment density/idiom. No version suffixes (ADR-0006). Keep the
  functional core pure and tested; the SwiftUI model is a thin `@Observable` that only
  fetches weather.

---

## The restraint (the whole point of ADR-0038)

Journey is a **read-only projection of `TripPlan`** (ADR-0038 §1–2). Concretely:

1. **No new persistent trip concept.** No `Journey`/`DaySummary`/`TripDay`/
   `WeatherLocation` record. The planning itinerary stays canonical.
2. **The projection is a pure value type in `GalavantSchema`**, not computed properties
   hung on the `@Observable` planning model (that is how a model gets fat — see the
   house "watch for fat models" rule), and not logic living in SwiftUI. The view receives
   a finished `JourneyProjection` and renders it.
3. **Weather is a garnish, not the backbone** (§6). >10 days out there is *no* forecast
   at all — which is most of a trip's life. A months-ahead trip must look finished with
   zero weather. Build the weather-free card first; layer weather in last.
4. **Forecasts never persist** (§6). Device-local cache only, keyed on WeatherKit's
   `expirationDate` + rounded coordinate — already handled by the shipped `WeatherClient`.
5. **Do not over-build to the concept renderings** (§8). They show the peak-loaded state
   (imminent departure, live weather every day, generated marketing art). The substance
   is: day story + stay bands + journey map + summary. See the cut list below.

---

## Ground truth — the reuse surface (verified 2026-08-16)

Everything Journey needs already exists on `TripPlan`; Journey projects over it.

- `TripPlan.lengthInDays: Int` (`TripPlan.swift:111`) — the day count to iterate.
- `TripPlan.itineraryItems(forDay:travelTimes:effectiveModes:now:tripStartDate:stays:)`
  (`TripPlan.swift:413`) — the per-day row stream (stops, `TravelConnector`s, `.checkIn`/
  `.checkOut`/`.homeBase`/`.calendarConstraint`, `.nowMarker`). Journey summarizes each
  day *coarsely* from this — it does not render the full row list (that's Today/planning).
- `TripPlan.stays: [ResolvedStay]` (`:294`) and `stays(coveringDay:)` (`:309`) —
  accommodation spans → the "stay bands" and "Night 2 of 3" (`TripStay.nights` is a Range).
- `TripPlan.region(forDay:) -> MapRegion?` (`:354`) + `dayRegions`/`regionsByID` (`:119`)
  — the per-day locality heading and a weather-anchor fallback coordinate. Package is
  MapKit-free; `MapRegion.centerLatitude/centerLongitude` are raw `Double?`.
- `Schedule` (`Schedule.swift:13`): `.timed(day,start:end:)` / `.daypart(day,part)` /
  `.day` ("Anytime") / `.unscheduled`. Day-relative times → wall-clock via
  `TripPlan.nominalDate` + `tripStartDate`.
- `TravelConnector.Kind`: `.betweenStops` / `.fromLodging` / `.betweenLodgings` — a
  `.betweenLodgings` connector on a day is the signal of a **transfer day** (origin AM →
  destination PM), which the day summary and its weather must not compress into one icon
  (ADR-0038 §4).
- `IdeaKind` (`IdeaKind.swift`): `outdoorTrail`/`beach`/`park`/`activity` drive weather
  sensitivity with no new field.
- Weather: `WeatherAnchor` (`TodayProjection.swift:466`) + its `WeatherRequestPolicy`
  `weatherGranularity` (`WeatherRequestPolicy.swift:12`); app-layer serving pattern in
  `Galavant/Today/TodayModel.swift:42` (`loadWeather(for:)` → `weatherClient.forecast(…)`
  → `WeatherSummary`). **Reuse this whole seam.**

---

## What Journey IS (the design)

An iPad, portrait-or-landscape, **read-only** surface for one trip. Four elements, in
rough vertical/z order — the weather-free version is complete on its own:

1. **The day story (spine).** One coarse card per trip day (`1…lengthInDays`): day
   number + date, the `TripDayRegion` locality heading, and a *compressed* sense of the
   day — e.g. the ordered stop titles / count, the defining activity, and a transfer
   marker on `.betweenLodgings` days ("Munich → Bavaria"). This is a *glance*, not the
   itinerary; tapping a day MAY open the existing day detail (read-only), but the default
   is comprehension, not drill-down.
2. **Stay bands.** Accommodations rendered as bands **spanning the nights they cover**
   (this is where ADR-0011's deferred span visualization finally lands — ADR-0038 §intro).
   A stay covering days 3–5 draws as one continuous band across those day cards, labelled
   with the hotel and "Night N of M".
3. **The journey map.** The whole-trip geography — day regions and the through-line
   between them (the "shape" of the trip). Reuse existing map geometry from `TripPlan`;
   this is display-only (no pins-to-edit, no pull affordances).
4. **The summary.** A quiet trip-level header/footer: date range, N days, regions
   visited, stay count. No AI themes, no marketing art (cut list).

**Weather (layered in last, coarse — §4/§6):** *one* anchor per day (not per stop),
resolved by the ADR-0038 §4 coordinate ladder but coarser: a located weather-sensitive
day-defining activity → the `TripDayRegion` center → a located covering stay → other day
geography → **omit**. Transfer days whose endpoints differ materially show the **split**
(origin AM → destination PM), never one compressed icon. Inside 10 days, daily forecasts
progressively appear per day card; beyond that, the cards simply carry no weather and
must look finished.

---

## iPad layout watch-outs

- **Do NOT nest a `NavigationStack` in the iPad split-view detail** (house memory: pushes
  pop). If Journey needs an in-panel drill-down (e.g. tap a day → day detail), use an
  **overlay swap**, not a nested stack. A modal sheet from Journey is also fine.
- Journey is **regular-width / iPad only** — gate it on `horizontalSizeClass == .regular`
  exactly as Today is gated the other way (`usesColumn`, `TripPlanningView.swift:50`). Do
  not build a compact iPhone Journey in V1 (Today is the iPhone surface).

---

## Slice sequence

### Slice J1 — the pure `JourneyProjection` core (no WeatherKit, fully unit-tested) ← build first

**Home:** `GalavantLibrary/Sources/GalavantSchema/` (new `JourneyProjection.swift`).
Tested in the existing `GalavantSchemaTests` target (reuse `TodayProjectionTests`
fixtures — the `plan(entries:ideas:)`/`stop(…)`/`stay` builders).

Deliver a pure `JourneyProjection: Equatable, Sendable`, a function of an already-built
`TripPlan` (+ `tripStartDate`, and the existing `travelTimes` map for any ETA/transfer
facts). No I/O, no MapKit, no WeatherKit.

- `days: [DaySummary]` — one per `1…lengthInDays`: `dayNumber`, `date`, `locality`
  (reuse the `TripDayRegion` resolution Today's `DayContext` already does), a compact
  stop digest (ordered titles + count), the defining/most-weather-sensitive stop if any,
  and an `isTransfer` flag + `from`/`to` endpoints derived from a `.betweenLodgings`
  connector on that day.
- `stayBands: [StayBand]` — one per `ResolvedStay`: the stay, its covered day range
  (`nights`), hotel title. The view lays these across the day spine; the *span math* is
  the projection's job (which days a band covers), not the view's.
- `summary: TripSummary` — date range, day count, distinct regions, stay count.
- A **day-level weather anchor**: add `WeatherAnchor.resolve(forDay:in:tripStartDate:)`
  alongside the existing stop-level `resolve(for stop:…)` (`TodayProjection.swift:498`).
  It implements the §4 ladder **coarsely** — one anchor for the whole day — reusing the
  private `coordinate(for:)` overloads and `isWeatherSensitive(_:)` already in that file.
  On a transfer day it MAY return a split (AM origin / PM destination); model that as two
  anchors on the `DaySummary` rather than one. Return `nil` (omit) when nothing locates.

**Tests:** build a multi-day plan with a stay spanning days 2–4 and a transfer on day 4;
assert day count, per-day localities, the stay band's covered range, `isTransfer` on the
right day with correct endpoints, and that the day-level anchor prefers a weather-sensitive
activity over the region center and omits when nothing locates. Keep everything a value
the view renders — no view logic in the core.

**Acceptance:** package compiles; `swift test --package-path GalavantLibrary` green;
projection is a pure function of `TripPlan` with zero I/O.

### Slice J2 — the iPad Journey SwiftUI surface (weather-free first)

**Home:** `Galavant/Journey/` (new): `JourneyView.swift` + a thin `@Observable`
`JourneyModel` (mirror `TodayModel`). Add the file(s) to `project.yml` → `xcodegen
generate` → commit both.

- Render the finished `JourneyProjection`: the day spine, stay bands drawn across the days
  they cover, the journey map, and the summary. **Build and verify the entirely
  weather-free layout first** — it is the primary design (§6).
- `JourneyModel` holds only the weather-fetch concern: for each day anchor, serve a
  `WeatherSummary` via `@Dependency(\.weatherClient)` exactly like `TodayModel.loadWeather`
  — one coordinated fetch per visible day anchor from the `expirationDate` cache, **not** a
  poll. Days with no anchor or >10-day horizon simply render no weather.
- Ship the **Apple Weather attribution** affordance on this surface (reuse
  `WeatherAttributionLink`) the moment any weather is shown (ADR-0038 §9).
- iPad layout per the watch-outs above (overlay swap for any drill-down, not a nested
  stack).

**Acceptance:** iPad-sim layout looks finished with zero weather; inside-10-days weather
fills per-day without a re-render storm; attribution present when weather shows.

### Slice J3 — entry / routing + polish

- **Routing decision (confirm with Jon):** where Journey lives. Sensible default — a
  Journey **mode/tab on the trip, iPad/regular-width only** (a segmented control or a
  sidebar destination on the trip), leaving the planning canvas and Today untouched. This
  is a navigation-policy change, not a data change; keep it minimal and reversible.
- Do **not** change `TodayModel`, the weather client, the day-stepper, or Today's gating.

---

## Explicitly OUT of V1 (ADR-0038 §8 cut list — do not build)

- **Per-region Highlights photography** and **AI-synthesized trip themes** ("Scenic
  Drives / Great Food"). Marketing chrome, not substance.
- **Severe-weather / minute-precip advisory** ("rain likely during your hike"). A
  fast-follow *after* base destination-time weather is trusted; advisory only — Galavant
  never auto-reschedules.
- **Device GPS / Core Location / "you are here".** Journey needs no live location.
- **Climatology / "typical for the season."** Never mix statistical with forecast weather.
- **A compact iPhone Journey.** Today is the iPhone surface.

---

## Watch-outs

- **Fat-model trap:** the span math, transfer detection, and anchor resolution all belong
  in `JourneyProjection` (pure, tested), never in `JourneyModel` or the view.
- **Transfer days must not lie:** one compressed weather icon for a day that starts in
  city A and ends in city B is exactly the failure §4 forbids — carry the split.
- **No-weather is not an error state:** it is the common case. If your card looks broken
  without weather, the design is wrong.
- **Nested NavigationStack in the iPad detail pops pushes** — overlay swap or sheet only.
- **Reactivity:** the projection recomputes from `@FetchAll`-observed `TripPlan`; don't
  cache derived facts in the view.
- **Verify, don't hand-wave:** `swift test --package-path GalavantLibrary` for the core,
  `xcodebuild build -scheme Galavant` for the app, and an iPad-sim install for the layout.

---

## Files

- `GalavantLibrary/Sources/GalavantSchema/JourneyProjection.swift` — new pure projection
  (+ day-level `WeatherAnchor.resolve(forDay:…)` added to `TodayProjection.swift`).
- `GalavantLibrary/Tests/GalavantSchemaTests/JourneyProjectionTests.swift` — new.
- `Galavant/Journey/JourneyView.swift` + `Galavant/Journey/JourneyModel.swift` — new
  (register in `project.yml`, regenerate, commit both).
- Entry point: a minimal, iPad-gated route into Journey from the trip (Slice J3, confirm
  placement with Jon).
