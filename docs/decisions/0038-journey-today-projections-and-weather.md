# ADR-0038: Journey and Today are read-only projections of `TripPlan`; a shared WeatherKit foundation forecasts planned presence, not the home base

*Status: **proposed** — 2026-08-15. Adds two new trip surfaces — **Today** (on-the-ground
iPhone cockpit) and **Journey** (iPad anticipation/comprehension view) — and one new
capability, **WeatherKit**. The load-bearing decision is a restraint: neither surface
introduces a persistent trip concept (`Journey`, `Today`, `DaySummary`, `TripDay`,
`WeatherLocation`). Both are pure projections of the existing `TripPlan` read model
(`GalavantSchema/TripPlan.swift`), consistent with the established shape **trip data →
`TripPlan` → task-specific presentation**. Preserves ADR-0001 (no server — WeatherKit is
device-direct), ADR-0003 (CloudKit-shared domain state — forecasts are **not** domain
state and never enter SQLite/CloudKit). Builds on ADR-0011 (stays as spans — Journey is
where the deferred span visualization finally lands), ADR-0012 (per-day region as the
locality heading), and the M3f now-marker + `DirectionsClient`/ETA cache. Seeds M10.
Sequencing decision (Jon, 2026-08-15): **build Today first**, dogfood it, then Journey.*

## Context

Galavant already has a strong functional read model. `TripPlan` (a pure, `Equatable`,
`Sendable` struct built from already-fetched arrays — no I/O) resolves itinerary days,
timed/daypart/anytime stops, accommodations spanning days, per-day regions, travel legs
with ETAs, map geometry, alternatives, calendar constraints, and a now-marker. The
`@Observable` planning model holds one and delegates read questions to it. Existing views
already project from it.

Two jobs are not yet served by the planning surface, and both are *presentation*
problems, not data-model problems:

- **Anticipation / comprehension.** "Make me want to *go* on the trip" — the shape,
  rhythm, geography, and character of the whole trip, at a glance. This is an iPad
  display surface, explicitly **not** another editing surface.
- **Execution.** "Make being *on* the trip effortless" — what's next, when to leave, how
  to get there, the weather where I'm actually going, what remains, where I sleep
  tonight, the shape of tomorrow. This is an iPhone cockpit.

A spot-check (2026-08-15) confirmed the underlying facts already exist in code: `TripPlan`,
`itineraryItems(…now:…)` with `.nowMarker`, the `Schedule` enum
(`.timed(day, start:end:)` / `.daypart(day, part)` / `.day` [displays "Anytime"]),
`TripStay` (`checkInDay`/`checkOutDay`/`nights`), `TripDayRegion` + `MapRegion` centers,
`TravelConnector.Kind` (`.betweenStops` / `.fromLodging` / `.betweenLodgings`),
`DirectionsClient` + ETA cache, open-in-Maps, and `IdeaKind`
(`outdoorTrail`/`beach`/`park`/`activity`/…). WeatherKit is **absent** in code — the one
genuinely new capability.

The risk is not "can we build it" — it is **scope discipline**: not letting two beautiful
presentation surfaces quietly become authoritative, and not over-building to the polished
concept renderings, which show the *peak-loaded* state (imminent departure, live weather
on every day, generated marketing art) rather than the common lifecycle state.

## Decision

### 1. Two projections, zero new persistent trip concepts

Journey and Today are **read-only projections of `TripPlan`**. The planning itinerary
remains the canonical trip. Neither surface persists anything; both answer different
questions from the same truth. No `Journey`/`Today`/`DaySummary`/`TripDay`/`WeatherLocation`
record is introduced. If a fact needs to survive, it belongs on `Trip`/`TripIdea`/
`TripStay`/`TripDayRegion` and is *reused*, never re-modeled here.

### 2. The projections are pure value types in the functional core; SwiftUI stays thin

Journey and Today derive as small, tested value types built from `TripPlan` (in
`GalavantSchema`), **not** as computed properties hung on the `@Observable` planning model
(that is how a model gets fat) and **not** as logic living in SwiftUI. The views receive a
finished projection and render it. This keeps the new logic testable as values, consistent
with the house rule of pulling read-model/join logic into the functional core.

### 3. The weather foundation splits at the package boundary: dumb client, pure anchor

Weather is the one new capability, seamed exactly like `DirectionsClient`:

- **`WeatherClient`** — an injectable app-layer `@Dependency`, dumb: `(coordinate, time
  window, granularity) → forecast`. It converts to `CLLocation` and calls WeatherKit. It
  makes **no** decision about *which* coordinate to ask about.
- **Weather-anchor resolution** — the "*which* coordinate, *which* time window" decision —
  is a **pure function over `TripPlan`** in `GalavantSchema`, tested as values, returning
  raw `lat/lon` + a time window. It never imports WeatherKit or MapKit.

This split is not merely preferred — it is **enforced by the module boundary**:
`GalavantSchema` is deliberately MapKit-free (coordinates are raw `Double?` throughout),
so the `CLLocation`/WeatherKit half physically cannot leak into the pure half. Anchor
resolution is testable without a network; the client is mockable without a trip.

### 4. Weather attaches to planned presence, not the day's home base

The product rule, made explicit:

> **Galavant forecasts the weather where the traveler is expected to be, at the time they
> are expected to be there. The lodging or day region is only a fallback.**

Anchor **coordinate** ladder (first that resolves wins):

1. A located, weather-sensitive activity that defines the item/day — especially
   `IdeaKind.outdoorTrail`/`beach`/`park`/`activity`.
2. The explicit `TripDayRegion` center (ADR-0012).
3. Located lodging (`TripStay`) covering that day.
4. Other located day geography.
5. **Omit weather** rather than show misleading weather.

Anchor **time window** maps onto the actual `Schedule` cases:

- `.timed(day, start, end)` → forecast across the real interval.
- `.timed(day, start, nil)` → start hour + a reasonable display window (no fabricated
  duration).
- `.daypart(day, part)` → the corresponding portion-of-day.
- `.day` (Anytime) / `.unscheduled` → broader daytime/daily.

Times are `"HH:mm"` + a day number, not `Date`s, so anchor resolution converts through
`tripStartDate` (`TripPlan.nominalDate`).

**Today** consumes this precisely: ambient "here now" weather stays a small top-strip
detail; the **NEXT hero** carries the *destination-time* forecast for weather-sensitive
items (correcting the concept rendering, which inverts this — it puts home-base weather up
top and leaves an outdoor hike with none). **Journey** consumes it coarsely (one anchor
per day); a transfer day whose endpoints differ materially shows the split
(origin AM → destination PM), not one compressed icon.

Amendment (Jon, 2026-08-20): Today also requests the previewed day's anchor, rendered at
the start of that day, so iPhone can surface advance daily forecasts while stepping through
the trip. This relaxes the original live-only Today rule: preview weather remains read-only,
appears only when WeatherKit has it within its horizon, and falls back cleanly to the normal
no-weather state beyond that horizon.

### 5. Leave-by is an honesty ladder tied to `Schedule`

Leave-by is a small new pure derivation, precise only when the schedule is:

- `.timed` → `leaveBy = start − ETA − buffer`, shown as a real clock time ("Leave by 10:45").
- `.daypart` → no clock time; "~12 min drive".
- `.day` (Anytime) / `.unscheduled` → "12 min away".

No fabricated precision from a mere itinerary position. ETA reuses `DirectionsClient` and
the `TravelConnector` legs (`.fromLodging` for hotel→first-stop). This lives in the
functional core alongside anchor resolution.

### 6. The no-weather state is the *primary* design; weather layers in late; nothing persists

WeatherKit's horizon is 10 days. For **most of a trip's life it is >10 days out and there
is no forecast at all.** Therefore the backbone of both surfaces is geography, rhythm, and
stays; weather is a garnish that appears only near departure. The degraded, weather-free
card is a first-class design, not an afterthought — a trip planned months ahead must look
finished with zero weather.

- >10 days out: no weather.
- Inside 10 days: daily forecasts progressively appear, including on Today preview days.
- During the trip: full coverage where available.

Forecasts are external, ephemeral, and independently recoverable, so they are **never**
persisted to SQLite/CloudKit. Caching is device-local only, keyed on WeatherKit's own
`metadata.expirationDate` and a rounded coordinate. No climatology/"typical for the season"
in V1 (do not mix statistical with forecast weather).

### 7. Today's runtime is one coordinated tick, not three polls

Today combines a **live clock**, **next-leg ETA refresh**, and **weather fetches** — which
uncoordinated becomes a polling storm re-rendering the hero every second and re-hitting
WeatherKit. V1 uses a single tick source; weather served from the `expirationDate` cache;
ETA on its own freshness policy (more aggressive than the planning screen's prewarm, still
bounded). This coordination is the fiddliest part of the initiative and is a deliberate
design point, not an emergent behavior.

### 8. Sequencing and the V1 cut list

**Today first**, dogfood, then Journey. The two surfaces share exactly one thing (the
weather foundation); otherwise they are independent, different-device surfaces. Today
carries the higher daily value and exercises the precise version of anchor resolution —
the part worth learning early.

Explicitly **out of V1** (deferred, may never be needed):

- Journey Highlights per-region photography and AI-synthesized trip themes ("Scenic
  Drives / Great Food") — the concept rendering shows these; they are marketing chrome,
  not the substance (day story + stay bands + journey map + summary).
- Severe-weather / minute-precip advisory ("rain likely during your hike after 1 PM") —
  a decision-relevance heuristic; a fast-follow once base destination-time weather is
  trustworthy. Advisory only; Galavant never auto-reschedules.
- **Device GPS / Core Location.** Galavant already knows coordinates for located places;
  WeatherKit takes a requested `CLLocation` that need not come from live GPS. "You are
  here" is a later improvement, not a V1 requirement.
- **Auto-entry into Today** (launching straight into the active-trip Today view on iPhone)
  is a navigation-policy change, not a data change — build and dogfood Today first, then
  decide.

### 9. Apple Weather attribution is required

WeatherKit requires the Apple Weather trademark + a link to its attribution/legal info. A
quiet, compliant attribution affordance ships with the first weather-bearing surface, even
though the concept renderings omit it.

## Consequences

- The "Exists" column is real: Journey and Today are overwhelmingly **reuse of `TripPlan`**
  plus one new dependency. `itineraryItems(…now:…)` already interleaves `.checkIn`/
  `.checkOut`/`.homeBase`/`.calendarConstraint`/`.nowMarker`, so Today's "check out by",
  Tonight boundary, and calendar obligations fall out of the existing stream.
- One new SPM-package-level concern (pure anchor + leave-by derivation, tested) and one new
  app-level dependency (`WeatherClient` + WeatherKit entitlement/capability, device-only
  verification like the FoundationModels seam).
- No schema migration, no CloudKit change, no new synced record.

## Alternatives considered

- **Persist a `TripDay`/`DaySummary`/forecast record.** Rejected: it duplicates `TripPlan`,
  invites staleness/sync problems for forecasts that are recoverable and ephemeral, and
  risks a projection quietly becoming authoritative (§1).
- **Call WeatherKit directly from SwiftUI / put anchor logic in the view.** Rejected:
  untestable, and it collapses the pure/dumb split the module boundary is there to enforce
  (§3).
- **One universal "weather for Day N."** Rejected: it lies on transfer days and on days
  whose defining activity is far from the home base — the opposite of the product rule (§4).
- **Ship Journey and Today as one interleaved effort.** Rejected: they share only the
  weather foundation; interleaving both device surfaces at once buys nothing and doubles
  the in-flight surface area (§8).
