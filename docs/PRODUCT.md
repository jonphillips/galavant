# Galavant — Product Brief

*Last updated: 2026-06-10*

## What it is

A private travel-planning app for **two people — Jon and his wife** — built around a
long-lived shared pool of travel ideas that feeds dated, curated trips. Never going
to the App Store; distributed to exactly two phones (plus iPads/Macs) via TestFlight.

## The core loop: collect → pull → schedule

1. **Collect** — either person captures an idea from anywhere (Safari share
   sheet, in-app browser, map search, manual entry) into one shared travel-party pool.
   The pool is geographic and eternal: ideas are bucketed by **map regions** and tags,
   and may sit for years. The pool is *designed* to be a junk drawer with good filters.
2. **Pull** — when a trip becomes real, its planning view shows the pool filtered
   through the trip's lens (regions, distance, not-yet-visited). Candidates are
   explicitly **pulled** onto the trip's shortlist. A trip never automatically
   contains anything.
3. **Schedule** — shortlisted ideas get ordered (priority negotiation) and
   placed onto itinerary days as stops, with V2's schedule granularity
   (unknown → approximated day/daypart → timed → exact).

**Canonical test case:** collect 38 Denmark ideas over four years; two years out, an
actual Copenhagen trip pulls the 12 that fit; the Skagen beaches stay in the pool,
unconsumed, for a someday-Jutland trip. After the trip, "done" and "skipped" statuses
flow back to the pool so future trips see an honest picture.

## Scoping the pool: map-and-filter as the "guide" (the Virginia case)

Saving an idea is itself the first filter — the pool is already "the world reduced
to things that interest us," like a personal map of saved pins, not a raw firehose.
So there is **no separate Boards/Guides entity** (ADR-0004); the *dynamic map+filter
view is the guide*, and the *trip shortlist is the curated output*.

The recurring example: we live near **Virginia** and take a Virginia trip most
years, hitting different ideas each time.

1. Open the pool map (PowerMap), scope to the **Virginia region** → only Virginia
   ideas show.
2. Layer **tag/kind filters** ("Michelin", food) → the visible pins thin to what fits.
3. Process them *visually on the map* — this is the thinking surface, not a scroll list.
4. **Pull** the ones that fit into the trip being planned (current or someday).

Why this needs the pull model (and forbids an `idea.tripID`): a **MapRegion is a
permanent geographic bucket**; many trips draw from it over years. After the 2026
Virginia trip, the places visited get marked **visited**; planning 2027, filter
**"not yet visited"** and the untouched ideas are still in the pool, waiting. The
same Virginia pin feeds a decade of annual trips, each pulling a different slice.

A curated "guide" you want to keep = a **someday-trip**: pull ideas into it (an idea
can be in several), and it grows dates to become the real trip — the curation done
while dreaming is never thrown away.

## Key model rule

An idea is never *in* a trip. Trip membership is a join record with a
lifecycle: `considering → shortlisted → scheduled → done / skipped`. Trips stay
clean; the pool stays intact; history feeds back.

## In scope

- Shared travel-party library: everything visible and editable by all party members, synced via iCloud
- Idea pool with region/tag/category/rating/visited filtering and map views
- Capture: Safari share extension (essential), in-app browser with page scraping, map search, manual entry
- Trips: regions, **optional dates** (duration + year/season until dates bind — see docs/trip-time-model.md), shortlist with drag-to-rank ordering, day-number-relative itinerary, stops with booking details
- Start-day solver: slide an undated trip's start date to check key stops are open on the weekdays they land on
- Platforms: iPhone, iPad, Mac

## Out of scope (deliberate — see docs/decisions/)

- **No custom server.** CloudKit only. (ADR-0001)
- **No social/community layer.** No boards browsing, following, public profiles, or collaboration beyond the two of us. (ADR-0001, ADR-0003)
- **No App Store release.** No onboarding for strangers, no account management UI, no free-tier customers.
- **No TCA.** (ADR-0002)
- **No Android/web** — accepted consequence of CloudKit. (ADR-0001)
- V1's standalone Boards entity — regions + tags do the bucketing. (ADR-0004)

## Prior art

- **V1** (`~/code/galavant/galavantios`) — feature-complete vision: boards, social,
  collaboration, share extension, scraping. Mine it for domain logic and the share
  extension/scraping approach.
- **V2** (`~/code/galavant/galavant-v2`) — architecture testbed: @Observable models,
  enum Destination navigation, generic Syncable, MapRegions, the Schedule enum,
  GalavantLibrary SPM package with tests. Mine it for patterns; V3 supersedes its
  persistence approach with SQLiteData.
