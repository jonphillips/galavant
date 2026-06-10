# Galavant

Private travel-planning app for Jon and his wife (two users, never App Store).
Core loop: shared idea pool → pull onto trip shortlist → schedule into itinerary.

## Read first

- `docs/PRODUCT.md` — what we're building and the explicit out-of-scope list
- `docs/decisions/` — settled architecture choices. **Check these before proposing
  architecture changes; don't re-litigate them.**
- `docs/STYLE.md` — house coding style (structs by default, functional core,
  impossible-states enums, swift-dependencies, no singletons). Consult the
  installed `pfw-*` skills (via `pfw-pfw`) when using Point-Free libraries.
- `docs/ROADMAP.md` — current milestone

## Stack (see ADR-0001/0002)

- SwiftUI multiplatform (iPhone/iPad/Mac), `@Observable` feature models
- SQLiteData for persistence + CloudKit sync (no server, no custom sync engine, no auth)
- swift-navigation enum-Destination pattern for navigation/sheets
- **No TCA.** Point-Free libraries yes, Composable Architecture no.
- Database lives in the app group container (share extension writes to it)
- Reusable modules go in the local SPM package, with tests

## Prior versions — mine these, don't import wholesale

See `docs/MINING.md` for the per-milestone port/adapt/skip inventory.

- V1: `~/code/galavant/galavantios` — full feature vision; share extension +
  SwiftSoup scraping; boards/social layer is deliberately dead
- V2: `~/code/galavant/galavant-v2` — better patterns: @Observable models, Destination
  enums, MapRegions, Schedule enum, GalavantLibrary package
- V1 server: `~/code/galavant/travelex` (Elixir) — the scraping/enrichment pipeline
  in `apps/travel/lib/travel/web_scraping/`; design distilled in
  `docs/scraping-enrichment.md`. (`~/code/galavant/galavantex` is the V2-era server;
  no scraping. Neither comes back — V3 enriches on-device.)

## Toolchain (June 2026 — WWDC26 cycle)

- Build with the **Xcode 27 beta**; keep Xcode 26 installed side-by-side as the
  fallback (first-beta compilers historically break macro-heavy libs like
  SQLiteData/StructuredQueries until Point-Free patches).
- **Deployment target: iOS 26** until a new API earns the bump (candidate:
  SwiftUI reorderable containers for M3's shortlist ranking). Wife's devices
  stay on stable OS.
- Xcode 27 ships Apple-authored agent skills (`swiftui-specialist`,
  `swiftui-whats-new-27`, …) exportable via `xcrun agent skills export` — link
  them into `~/.claude/skills` after installing the beta. New OS-27 APIs are
  past Claude's training cutoff; prefer those skills + current docs over memory.

## Conventions

- Keep dependencies minimal; each new package needs a reason
- **No version suffixes anywhere in the namespace** (ADR-0006): project, targets,
  modules, bundle ID, app group, CloudKit container are plain Galavant. "V3" is
  docs-only history.
- UUID primary keys everywhere (CloudKit schema rules)
- No `mine`/ownership flags — everything is household-shared (ADR-0003)
- 2-space indentation (Jon's existing style)
- When SQLiteData API questions arise, check current docs — the library moves fast
