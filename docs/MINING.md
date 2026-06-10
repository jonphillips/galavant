# Mining map — what to pull from V1/V2, when, and what to leave buried

*One-time inventory (2026-06-10) so milestones don't rediscover or forget
assets. Rule: nothing is pasted wholesale — every port crosses the STYLE.md
boundary (structs, async/await, @Dependency, swift-testing) on the way in.
Verdicts: **port** (logic survives mostly intact), **adapt** (the idea
survives, the code is reference), **skip** (superseded or dead).*

Paths: V1 = `~/code/galavant/galavantios`, V2 = `~/code/galavant/galavant-v2`,
V1 server = `~/code/galavant/travelex`.

## M0–M1 (skeleton, CloudKit)

Nothing. V2's entire persistence/sync layer is superseded: GRDBQuery
`@Query`/Publishers/Queries → SQLiteData `@FetchAll`; `Syncable`/
`SyncService`/`UploadService` → SyncEngine; `World.swift`/`AppCurrent` →
swift-dependencies; `Authentication/` + `GalavantKeychain` → deleted concepts
(iCloud is the identity). Greenfield against pfw-sqlite-data docs.

## M2 (the pool)

- **Port:** V2 `MapRegion` struct (Itinerary.swift) — add UUID PK, CloudKit-legal
  schema. V2 `MapUtilities.regionContains` + filtering predicate logic from
  `AttractionsFilterable` (pure parts). V1 `PlaceSearchStrategy` (pure functions,
  STYLE.md exemplar).
- **Adapt:** V2 `DefineMapRegion`/`DefineMapRegionModel` (UI for drawing regions);
  V2 `AttractionsIndexModel` shape (the filter-state surface: search text, kinds,
  ratings, regions, distance, sort); V1 `PowerMap` (capability-flag map view —
  rebuild on modern SwiftUI `Map`, it predates MapKit-for-SwiftUI maturity).
- **Skip:** V2 `Attraction` record + DataQuery/FormData extensions (new Idea
  schema instead); `RepoState`/`DataLoaderView` loading-state machinery
  (@FetchAll makes it unnecessary).

## M3 (trips)

- **Port:** V2 `Schedule` enum (Event/Scheduling.swift) including
  `startsAtIntraDaySort`; V2 `Trip` date-span/regions logic and `Itinerary`
  day-derivation (pure parts).
- **Adapt:** V2 `TripPlan`/`TripPlanModel` (day sections, per-day region stops);
  drag-to-rank — prefer iOS 27 reorderable containers if the deployment-target
  bump is taken (CLAUDE.md toolchain note).
- **Skip:** V1 RankList entity (reborn as shortlist ordering, ADR-0004);
  V1 TripActivity flag-soup scheduling fields.

## M4 (capture)

- **Port:** V1 share extension skeleton (`galavantShare/`) esp.
  `ExtensionPreProcessing.js` (rendered-DOM handoff); V1 `WebScraping.swift` +
  SwiftSoup usage as parser reference.
- **Adapt:** the whole enrichment design from the V1 *server* — already
  distilled in `scraping-enrichment.md` (tag-mapping tables, value voting,
  two-hop, MapKit-authoritative merge). V2 `WebSearchModel`/WebViewStore for
  the in-app browser.
- **Skip:** V1's UserDefaults-JSON board handoff (app-group DB replaces it);
  per-site scrapers until a real capture fails.

## M5 (polish)

- **Port:** V2 `PrefersTabNavigation` environment shim; V2 GalavantLibrary
  `UnsplashSearch` + `LocationMapSelector` packages (already tested SPM modules —
  closest thing either repo has to V3-ready code).
- **Adapt:** V2 `Navigation/` scaffolding (AppTabView/AppSidebarList/
  AppDetailColumn); small widgets only on demand (TextFieldWithLabel,
  YearSeasonPicker).
- **Skip:** V1's 30-file widget zoo (most exist in modern SwiftUI now);
  V1 Theme/ (restyle fresh).

## Never port (superseded by ADRs)

Both repos' sync/upload managers and `Server*`/`Remote` twin models (ADR-0001);
all `mine`/ownership flags (ADR-0003); Boards + bookmarks + follows +
collaboration + community (ADR-0003/0004); V1's GraphQL client; anything
holding `AppCurrent`/`UniverseCurrent` (STYLE.md §4). Known V2 bugs die with
it: `SyncService.shared` returns an `UploadService`; mixed
callback/async database API.
