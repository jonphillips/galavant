# ADR-0027: GalavantWeb lifted to the shared `WebExtractorKit` package

*Status: accepted — 2026-06-30*

## Context

`GalavantWeb` (ADR-0022 / 0024 / 0025) was always built as the **act of browsing** —
domain-free, plugin-driven, imports only Foundation/SwiftUI/WebKit. ADR-0022 named the
eventual cross-app reuse explicitly: "the browsing capability will be reused in a
separate app (a recipe app)."

That second consumer now exists. Yes Chef (the recipe app) had already copy-vendored a
`RenderedDOMFetcher` that diverged from ours. jon-platform's cross-app ADR-0001 set the
house rule for exactly this: when a second app consumes a domain-free module, lift it
to a neutrally-named shared package — a *rename-and-move, not a copy*.

## Decision

The `GalavantWeb` module is **lifted out of `GalavantLibrary` into the shared
`WebExtractorKit` package** in jon-platform (`~/code/jon-platform/packages/
WebExtractorKit`), per **jon-platform ADR-0002**. Galavant now depends on it by local
path.

- **Removed** from `GalavantLibrary`: the `GalavantWeb` library/target/test target and
  its sources.
- **Added**: a path dependency on `WebExtractorKit` in `GalavantLibrary/Package.swift`
  (`GalavantPlaces` links it) and in `project.yml` (the app target links it; XcodeGen
  is source of truth). `GalavantShare` needs no entry — its link is transitive through
  `GalavantPlaces`.
- **Imports** updated `import GalavantWeb` → `import WebExtractorKit` in
  `GalavantPlaces/PageFetcher.swift`, `Browser/BrowserScreen.swift`,
  `Browser/BrowserScreenModel.swift`, `Ideas/IdeaFormView.swift`. Symbol names are
  unchanged.

ADR-0022/0024/0025 remain the design history of the module; this ADR only records that
its source of truth moved out of this repo.

## Consequences

- Galavant's hours / rating / guide extractor plugins, start pages, and browser screens
  stay here (domain-bound); only the domain-free browsing/DOM machinery moved.
- Editing the browser now means editing `WebExtractorKit` in jon-platform; both apps
  pick it up by local path.
- A sibling jon-platform checkout is now required to build galavant
  (`../../jon-platform`).
