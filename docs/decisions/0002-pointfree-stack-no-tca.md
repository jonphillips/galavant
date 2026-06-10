# ADR-0002: Point-Free libraries, but not TCA

*Status: accepted — 2026-06-10*

## Decision

- **Persistence/observation:** SQLiteData (successor to SharingGRDB) — `@FetchAll` /
  `@FetchOne`, StructuredQueries, CloudKit sync. Replaces V2's GRDBQuery `@Query`.
- **Navigation:** swift-navigation / SwiftUINavigation — enum `Destination` state per
  feature model, as V2 already proved out.
- **State:** plain `@Observable` feature models (V2 pattern: `AttractionsIndexModel`,
  `TripPlanModel`, …). One model per screen/feature, owning its Destination enum.
- **Supporting:** swift-dependencies where DI is needed; CustomDump + IssueReporting
  in tests/debug (pfw skills are installed for these).
- **Explicitly not TCA.** Jon is a Point-Free devotee but does not want to go all-in
  on the Composable Architecture.

## Why

V2 validated @Observable + enum-destination navigation and it fit how Jon thinks.
TCA's ceremony isn't wanted for a two-person household app. SQLiteData is the one
new bet, chosen because its CloudKit sync is the linchpin of ADR-0001.

## Conventions

- Reusable, app-agnostic modules go in a local SPM package with tests
  (V2's GalavantLibrary pattern: APIClient, UnsplashSearch, LocationMapSelector are
  candidates to port).
- Keep the dependency list short; every new package needs a reason.
