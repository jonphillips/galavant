# Galavant

Private travel-planning app for Jon and his wife (two users, never App Store).
Core loop: shared idea pool → pull onto trip shortlist → schedule into itinerary.
[`docs/PRODUCT.md`](docs/PRODUCT.md) has the scope and the explicit out-of-scope list.

## Working mode

Architect / executor, per jon-platform `AGENTS.md` (since 2026-09-29).

## Read first

1. `~/code/jon-platform/AGENTS.md`: the house stack and rules. Galavant's docs hold only the
   **travel domain**.
2. [`docs/README.md`](docs/README.md): the map of this repo's docs.
3. [`docs/STYLE.md`](docs/STYLE.md): Galavant's examples of the house style, numbered to match
   jon-platform's `swift-style.md`.

`docs/DONE-LOG.md` (75 KB) and `docs/archive/` are grepped for the section you need, never read whole.

## What's Galavant's own

- **SwiftUI multiplatform** (iPhone, iPad, Mac), bound by ADR-0001 and ADR-0002. The database lives
  in the app group container because the share extension writes to it.
- **On Production since 2026-10-08** (`docs/PROD-CUTOVER.md`, ADR-0049). The house rules are in
  jon-platform `persistence-and-sync.md` § Once an app is on Production. On top of them:
  - Xcode Run builds **Galavant Dev** (ADR-0050), which installs next to TestFlight.
  - Once the travel party is shared, a restore is a two-person event (ADR-0049 D2).
- **Deployment target iOS 27**, for SwiftUI `reorderable()`. Don't raise it without an API that
  earns it, because his wife's devices stay on the stable OS.
- **Known issues** live in `docs/KNOWN-ISSUES.md`. Re-verify each against the release build before
  keeping its workaround.
- **Prior versions are mined, never imported wholesale.** V1 (`~/code/galavant/galavantios`), V2
  (`~/code/galavant/galavant-v2`), and the V1 Elixir server (`~/code/galavant/travelex`); see
  `docs/MINING.md` and `docs/scraping-enrichment.md`. Boards, social features, and the server are
  deliberately dead, and enrichment is on-device.
- **No version suffixes anywhere in the namespace** (ADR-0006). The project, targets, modules,
  bundle ID, app group, and CloudKit container are plain Galavant. "V3" is docs-only history.
- **No `mine` or ownership flags.** Everything is shared with the travel party (ADR-0003).
