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
- ✅ Capture polish: **search-first form** — place search leads, auto-populates name/kind/link/address/phone from MapKit (`MKMapItem` + pure `IdeaKind` POI mapping); ⏳ Tags (first-class?); ⏳ location-search robustness (region-bias — docs/BACKLOG.md)
- ⏳ Second-device identity hardening (ADR-0008): bind-or-create planner picker, stray-party cleanup, IdeaInterest dedup-on-read
- Full Idea model: kinds, visited state, tags, URLs, images, opening days/hours and reservable-from (manual entry)
  - **Image storage strategy** (cross-cutting; inherited by M4 scraped images + M5
    Unsplash headers) — now settled in **ADR-0009**: CloudKit-native (no S3),
    pure processing split from stack-specific storage, a dedicated image table,
    resize-on-import display tier (~1600px/≈300 KB inline BLOB) with `CKAsset`
    full-res deferred. See the ADR before building.
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
- ✅ M3c (2026-06-13): **the itinerary core** — day-relative scheduling. New
  `Schedule` facade (`unscheduled / day / daypart(DayPart) / timed`, dates never
  stored — derived from start; drops V2's `.exact`) over four flat columns on
  `TripIdea` behind the `Certainty`-style apply/rebuild contract; `DayPart` enum
  (Int-raw, `sortHour`). Functional core: `TripIdea.itinerary(_:lengthInDays:)`
  → `[ItineraryDay]` (every day present, intra-day sorted by `intraDaySort` then
  `shortlistRank`, out-of-range days clamp onto the last); `Trip.date(forDay:)`
  derives the calendar date for dated trips. DB ops `schedule`/`unschedule`/
  `markDone` (Done flips `Idea.visited` — post-trip feedback-to-pool, ADR-0004).
  UI: third **Itinerary** segment in the planning screen — day sections (header
  shows day # + weekday/date when dated) plus a **To Be Scheduled** bucket at the
  top for stops committed to the trip but not yet placed on a day (`.scheduled`
  with `dayNumber == nil`); an **Add Stop** sheet (pick idea + day or
  to-be-scheduled + time-of-day), per-stop menu to set/move day / set
  time-of-day / Skip / back-to-shortlist, and a swipe-to-Schedule on shortlist
  rows. Ideas page is **Ideas | Itinerary** with shortlist/scheduled/considering
  sections, one-tap state icons, and swipe Remove/Unschedule. 11 new tests (43 total). **Done is intentionally not a
  per-stop action** (Jon: completion is assumed once the trip passes) — the
  `markDone`→`visited` op stays as the mechanism for a future trip-level rollup +
  a "now" marker (docs/BACKLOG.md). Deferred: clock-time *entry* UI, drag stops
  between days, freeform (non-idea) stops, accommodations, per-day region stops
  (`.timed` + schema already support the first). `TripRegion` join (single-FK→Trip ON DELETE CASCADE, loose regionID per ADR-0007) with `setRegions` reconcile + `regionIDs(forTrip:)`. `poolFiltered` now takes a region **union** (`regions: [MapRegion]`, empty = no constraint, match any); IdeasListModel + tests updated. Multi-region picker in the trip form; the Add lens (`Set<MapRegion.ID>`) **pre-seeds from the trip's regions** on appear. Demo trips pre-associated with regions. 32 tests green. (Reorder-on-fast-nav race parked as a beta-watch item — docs/KNOWN-ISSUES.md.)
- ✅ M3d (done, 2026-06-14): **map-as-canvas trip view** — the map is the
  trip's home (docs/trip-canvas.md). Full-bleed `TripCanvasMapView` with numbered,
  day-coloured sequence pins + per-day `MapPolyline`; a `DayChipBar` lens (All +
  Day 1…N) framing the camera via the pure `MapFraming` core (no MapKit, tested);
  the **Itinerary | Ideas** list surface (`TripDetailContent`) is the second
  projection of one shared selection (`canvasSelectedStopID`), with a pinned
  switcher and pin-tap→list autoscroll. **Platform split:** iPhone gets a
  persistent Apple-Maps-style bottom sheet; iPad gets a solid right-hand column
  beside the map (`horizontalSizeClass`) so map + itinerary are usable at once.
  Edit sits in the trip nav toolbar. Model `Mode`→`SheetTab` + canvas
  selection/lens state; `StopMenu` extracted; `TripItineraryView` gains
  `focusedDay` + selectable rows. 49 GalavantSchema tests green; builds clean.
  **Travel-time connectors deferred to M3e** (canvas only). (Metal API Validation
  off in the Run scheme — MapKit trips a false assert on the iOS 27 sim beta;
  docs/KNOWN-ISSUES.md.)
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
