# Galavant Roadmap

Vertical slices; each milestone ends with something that runs. Riskiest unknowns
first. Update this file when reality diverges — it's a living doc, not a contract.

## M0 — Skeleton that persists ✅ (done 2026-06-10, Xcode 27 beta 1)
- Xcode project: multiplatform SwiftUI app + share-extension target stub + local SPM package
- SQLiteData wired up; database in the **app group container** from day one
- Minimal `Idea` model (name, coordinate, region, notes) with CloudKit-legal schema (UUID PKs)
- List + add/edit form proving @FetchAll observation and swift-navigation Destination pattern
- ✅ Done when: add an idea on iPhone sim, relaunch, it's still there

## M1 — The CloudKit bet ✅ (2026-06-12, architecture proven)
- ✅ SQLiteData CloudKit sync live (SyncEngine over travelParties+ideas; container iCloud.com.jonphillips.galavant)
- ✅ Two-device sync on one account — both directions, ~10s latency (sim 17 Pro ↔ 17 Pro Max)
- ✅ Travel-party share CREATED over the full graph (TravelParty root + ideas); valid share URL
- ⏳ Accept handshake deferred to real-device test at M5/TestFlight (simulator can't route it; ADR-0003)

## M2 — The pool *(in progress)*
- ✅ M2a: TravelParty/Planner/IdeaInterest schema, kinds, per-planner first-run identity, his/hers interest UI
- ✅ M2b: MapKit location search in the form (idea gets coordinates) + pool map with pins + list/map toggle
- ✅ M2c: first-class MapRegion (containment-based), pool filter (region/kind/visited), filter UI + define-region-from-map, filter-summary bar
- ⏳ Tags (first-class?); capture polish (search-first form, auto-populate from MapKit — docs/BACKLOG.md)
- ⏳ Second-device identity hardening (ADR-0008): bind-or-create planner picker, stray-party cleanup, IdeaInterest dedup-on-read
- Full Idea model: kinds, visited state, tags, URLs, images, opening days/hours and reservable-from (manual entry)
- Planner identity (ADR-0007): Planner table, device-local currentPlannerID, first-run name capture
- **Per-planner flames ratings + notes** via single-FK Rating record (Must Do…Decide Later, his-and-hers; ADR-0007)
- MapRegions (port V2's working implementation) + region/tag/category/distance filtering
- Capture via MapKit search + manual entry
- Pool map view (PowerMap descendant)
- ✅ Done when: the Denmark junk drawer works — collect, filter, browse on a map

## M2→M3 — Adaptive nav shell ✅ (2026-06-12)
- ✅ AppContainer: tabs on iPhone, sidebar+detail split on iPad/Mac (prefersTabNavigation, ported from V2). AppScreen sections: Ideas (real) + Trips (placeholder). Fixes the "stretched iPhone" iPad layout.

## M3 — Trips
- ✅ M3a: Trip schema (certainty pipeline someday(rank)→targeted(year,quarter)→dated + lengthInDays, flat columns behind a `Certainty` enum facade) + TripIdea join with `considering→shortlisted→scheduled→done/skipped` status (ADR-0004); functional core (`Trip.create`/`update`/`reorderSomeday`/`sectioned`, `TripIdea.pull`/`setStatus`/`remove`) + 13 tests; Trips list grouped by certainty with create/edit form and reorderable() someday backlog (deployment target bumped to iOS 27 for native reorder). Demo trips seeded.
- ✅ M3b: pull-to-shortlist. Tapping a trip pushes a **Trip Planning screen** (segmented Shortlist | Add); Add shows the pool scoped by the reused M2c filters (region/kind/tag/visited) with pull → considering / straight-to-shortlist; Shortlist shows ranked pulls (reorderable()) + a Considering pile; per-row status menu (considering/shortlisted/scheduled/skipped/remove). Core: `TripIdea.reorderShortlist` + rank-on-promote in `setStatus` + pure `shortlist()`/`considering()`; 3 new tests (29 total). Edit moved into the planning screen. Title fix: trip name now shows (segmented control moved to a bar under the nav bar).
- ⏳ M3b.1 (agreed 2026-06-13): **persist multiple regions per trip** — `TripRegion` join (single-FK→Trip, loose regionID per ADR-0007); extend `poolFiltered` to a region *union* (`regions: [MapRegion]`, empty = no constraint); multi-region picker in the trip form; the Add list pre-selects the trip's regions (filter state becomes `Set<MapRegion.ID>`). Update IdeasListModel + RegionFilterTests to the new `poolFiltered` signature. (Reorder-on-fast-nav race parked as a beta-watch item — docs/KNOWN-ISSUES.md.)
- Trip model: **certainty lifecycle** someday(rank) → targeted(year, quarter) → dated (docs/trip-time-model.md); duration in days; **day-number-relative itinerary** + **TripIdea join with status lifecycle** (ADR-0004)
- Trips list grouped by certainty; drag-rank the someday backlog; trip link bookmarks (label+URL)
- Planning view: pool filtered by trip lens → pull to shortlist
- Shortlist drag-to-rank ordering
- Itinerary: days, per-day regions (with percentDay splits), stops with the V2 Schedule enum; "bookable now / opens in N days" section on dated trips
- Post-trip: done/skipped feedback to pool
- Map-as-canvas trip view: day chips, numbered sequence pins, bottom-sheet timeline (docs/trip-canvas.md)
- Travel-time connectors between a day's stops (MKDirections ETAs, gap conflicts) + open-in-Maps handoff
- Stretch: start-day solver (slide start date → check key stops' open days; docs/trip-time-model.md)
- ✅ Done when: the Copenhagen scenario works end to end

## M4 — Capture from anywhere
- Share extension: URL in → scraped page (SwiftSoup, port V1) → idea form → saved to shared DB
- Enrichment pipeline per `docs/scraping-enrichment.md` (port of the V1 server's
  metatag/OpenGraph/schema.org layering, value voting, and MKLocalSearch matching; add JSON-LD and openingHours capture)
- In-app browser capture flow (port V2's WebSearch)
- ✅ Done when: share a restaurant page from Safari, it's in the pool with image and location, and it syncs

## M5 — Polish & distribution
- iPad/Mac split-view layouts properly done
- Weather chips on itinerary days: climate normals when far out/undated, WeatherKit forecast inside 10 days (docs/trip-canvas.md)
- Unsplash header images (port GalavantLibrary's UnsplashSearch) if still wanted
- Sync health surface: show whether CloudKit sync is active or local-only (silent degradation is fine for dev, not for two-person use)
- TestFlight setup; app on wife's phone
- Future/backlog: booking-window local notifications with time-of-day precision (the 3 a.m. hard-to-get-restaurant alarm — docs/recovered-requirements.md Q2)
- ✅ Done when: both phones run it daily
