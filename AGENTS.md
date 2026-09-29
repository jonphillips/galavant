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
- `docs/CURRENT_HANDOFF.md` — what's active now; start here. `docs/ROADMAP.md`
  (44 KB) and `docs/DONE_LOG.md` (75 KB) are grepped for the section you need,
  never read whole.

## Stack (see ADR-0001/0002)

- SwiftUI multiplatform (iPhone/iPad/Mac), `@Observable` feature models
- SQLiteData for persistence + CloudKit sync (no server, no custom sync engine, no auth)
- swift-navigation enum-Destination pattern for navigation/sheets
- **No TCA.** Point-Free libraries yes, Composable Architecture no.
- Database lives in the app group container (share extension writes to it)
- Reusable modules go in the local SPM package, with tests

## Prior versions

V1 (`~/code/galavant/galavantios`), V2 (`~/code/galavant/galavant-v2`), and the V1 Elixir server
(`~/code/galavant/travelex`) are mined, never imported wholesale — see `docs/MINING.md` and
`docs/scraping-enrichment.md`. Boards/social and the server are deliberately dead; enrichment is
on-device.

## Toolchain (Xcode 27.0)

- Xcode 27.0 at `/Applications/Xcode.app` is the default toolchain; the iOS 27 simulator runtime
  (iPhone 17 family) is installed.
- **Deployment target: iOS 27** (for SwiftUI `reorderable()`). Don't bump further without an API
  that earns it — wife's devices stay on stable OS.
- OS-27 APIs are past model training cutoffs: prefer Apple's exported agent skills
  (`swiftui-whats-new-27`, …; refresh per jon-platform `skills/SETUP.md`) and current docs over memory.
- Known issues live in `docs/KNOWN-ISSUES.md`; re-verify against the release build before keeping
  a workaround.

## Context management

Follow jon-platform `docs/agent-workflow.md` § Context management and § Token discipline. The
repo (docs, ADRs, CURRENT_HANDOFF, DONE_LOG) plus auto-memory hold all durable state, so suggest
a fresh session at commit/milestone boundaries when context is heavy and the tree is clean.

## Verifying

`scripts/check-drift.sh` is the single entry point: SwiftLint, `swift test
--package-path GalavantLibrary`, and a `build-for-testing` pass that compiles and
links `GalavantUITests`. Each stage runs through jon-platform's `quiet-run`,
so only errors and verdicts print; the full logs stay on disk. It never boots a simulator — running the UI tests is a
separate, deliberate step.

That last stage exists because `GalavantUITests` is compiled by nothing else here
and run by nothing in CI, which is precisely how a test target rots without
anyone noticing. `GALAVANT_SKIP_TEST_BUILD=1` skips it and says loudly that it
did.

- **Declare what you use, even when you got it for free.** `import SQLiteData`
  hands you GRDB's `Database`/`DatabaseWriter` via `@_exported`, but that is a
  compile-time re-export only. Static builds resolve it anyway; the moment
  anything makes SwiftPM products dynamic, an undeclared dependency is a link
  failure. If a target uses a type, its manifest should name the package.

## Conventions

- Keep dependencies minimal; each new package needs a reason
- **No version suffixes anywhere in the namespace** (ADR-0006): project, targets,
  modules, bundle ID, app group, CloudKit container are plain Galavant. "V3" is
  docs-only history.
- UUID primary keys everywhere (CloudKit schema rules)
- No `mine`/ownership flags — everything is travel-party-shared (ADR-0003)
- 2-space indentation (Jon's existing style)
- When SQLiteData API questions arise, check current docs — the library moves fast
