# Galavant

Private travel-planning app for Jon and his wife (two users, never App Store).
Core loop: shared idea pool → pull onto trip shortlist → schedule into itinerary.

## Read first

- `~/code/jon-platform` — Jon's **cross-app house knowledge base** (general style,
  architecture, persistence/sync laws, toolchain, agent workflow). Read its
  `AGENTS.md` / `docs/` before proposing architecture or style. Galavant docs below
  hold only the **travel domain**; general decisions live in jon-platform. When you
  learn a *general* preference, update jon-platform; keep galavant-specific
  preferences here (triage rule in jon-platform's `docs/agent-workflow.md`).
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

- Build with the **Xcode 27 beta** at `/Applications/Xcode-beta.app` via
  `export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` —
  do not `xcode-select -s`; Xcode 26.5 at `/Applications/Xcode.app` stays the
  system default fallback (first-beta compilers historically break macro-heavy
  libs like SQLiteData/StructuredQueries until Point-Free patches).
- iOS 27 simulator runtime is installed (iPhone 17 family). Old iOS 17
  runtimes also present — ignore them.
- **Deployment target: iOS 27** — bumped in M3a for SwiftUI's native
  `reorderable()` (the someday-backlog drag-to-reorder). Don't bump further
  without an API that earns it; wife's devices stay on stable OS.
- Xcode 27 ships Apple-authored agent skills (`swiftui-specialist`,
  `swiftui-whats-new-27`, …). Export via
  `xcrun mcpbridge run-agent skills export --output-dir ~/.claude/skills` —
  **requires Xcode-beta to be running** (errors otherwise; retry after Jon has
  launched it once). New OS-27 APIs are past Claude's training cutoff; prefer
  those skills + current docs over memory.
- Beta-sensitive bugs (likely Xcode/SDK beta regressions) live in
  `docs/KNOWN-ISSUES.md` — re-verify them on each new beta before working around.

## Context Management
- **Start a fresh conversation at commit/milestone boundaries** (not every task —
  our exploratory multi-task sessions are fine). The repo (CLAUDE.md, docs/,
  ADRs, ROADMAP, BACKLOG) + auto-memory hold all durable state, so a new session
  resumes with zero loss. Suggest a fresh start when context is heavy AND the
  tree is clean (committed).
- **Don't paste large tool output** (crash reports, full compiler command lines,
  whole build logs). Save to a file and tell Claude the path, or paste only the
  error line — Claude greps/tails logs itself.
- Prefer targeted file reads over re-reading whole files; use subagents for broad
  codebase searches (they return just the conclusion).
- `/compact` mid-task if context-heavy but not ready to stop; a fresh session is
  better when you are.

## Conventions

- Keep dependencies minimal; each new package needs a reason
- **No version suffixes anywhere in the namespace** (ADR-0006): project, targets,
  modules, bundle ID, app group, CloudKit container are plain Galavant. "V3" is
  docs-only history.
- UUID primary keys everywhere (CloudKit schema rules)
- No `mine`/ownership flags — everything is travel-party-shared (ADR-0003)
- 2-space indentation (Jon's existing style)
- When SQLiteData API questions arise, check current docs — the library moves fast
