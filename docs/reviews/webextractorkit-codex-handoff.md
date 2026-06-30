# Handoff: leveraging `WebExtractorKit` (for a fresh session → Codex prompt)

*Written 2026-06-30. Purpose: everything a new session needs to write a Codex
build-order prompt that puts the freshly-extracted browser to new use. This is
**context for writing that prompt**, not the prompt itself.*

## What just happened (state of the world)

`GalavantWeb` was lifted out of `GalavantLibrary` into a **single-source shared SPM
package**, `WebExtractorKit`, now living in jon-platform.

- **Package:** `~/code/jon-platform/packages/WebExtractorKit` (jon-platform's first
  hosted source code; the repo was docs-only before). SwiftUI + WebKit only, no
  external deps, multiplatform (iOS 26 / macOS 26). 8/8 tests pass.
- **galavant** consumes it **by local path** (`../../jon-platform/packages/
  WebExtractorKit` in `project.yml`; `../../../` in `GalavantLibrary/Package.swift`).
  Builds for iPad Pro 13 M5. `GalavantShare` links it transitively via `GalavantPlaces`.
- **PRs open, not merged:** jon-platform #15, galavant #43 (cross-linked; galavant
  depends on jon-platform's package existing at the sibling path).
- **ADRs:** jon-platform ADR-0002 (the lift + the `packages/` direction), galavant
  ADR-0027 (galavant's side). Design history stays in galavant ADR-0022/0024/0025.
- **Build rule (memory):** XcodeGen `project.yml` is source of truth — every product a
  target imports directly MUST be declared, or `xcodegen generate` drops the link →
  Undefined symbols. `WebExtractorKit` is now in `packages:` and on the `Galavant`
  target.

**Open follow-up already flagged (separate PR):** Yes Chef
(`~/code/cooking/yes-chef`) still has a copy-vendored, *diverged* `RenderedDOMFetcher`
(`YesChefApp/RenderedDOMFetcher.swift`, predates `WebPage.currentDOM()`). Rewiring it
onto `WebExtractorKit` and deleting the copy is its own task — **not** part of any
"leverage the browser" work below.

## The package's public API (what a consumer plugs into)

The whole module is the **act of browsing**; the caller injects the domain logic. Four
surfaces:

1. **`WebExtractorBrowser`** — modal "go fetch one thing and come back" session.
   ```swift
   WebExtractorBrowser(
     startURL: URL, title: String, confirmLabel: String,
     onExtract: (_ html: String, _ sourceURL: URL?) async -> WebExtractionOutcome
   )
   ```
   `onExtract` is the plugin seam: it gets the rendered `outerHTML` + URL, parses/
   persists on the caller's side, returns `.extracted` (dismiss) or
   `.notFound(message:)` (stay open, show message, let user navigate & retry).
   *Galavant uses this twice today:* `Ideas/IdeaFormView.swift:131` ("Find Hours") and
   `:150` ("Find Rating").

2. **`WebBrowserView<Accessory, Home, FieldBar>`** — persistent, full-chrome browser
   (address bar, back/forward, home surface). Generic over three `@ViewBuilder` slots;
   has a no-field-bar convenience init. Host owns the `WebPage` so nav state survives.
   *Galavant uses this* in `Browser/BrowserScreen.swift:27` (+ `WebFieldCaptureBar` at
   `:41`), driven by `Browser/BrowserScreenModel.swift`.

3. **`RenderedDOMFetcher.renderedHTML(of:) async -> String?`** — viewless, unattended
   render (render-on-miss fallback). *Galavant uses it* in
   `GalavantPlaces/PageFetcher.swift:75`.

4. **Helpers:** `WebAddress.resolve(_:search:)` / `.duckDuckGo`; `WebPage.browser()`,
   `WebPage.currentDOM()`, `WebPage.currentSelection()` (extension on `WebPage`);
   `WebCaptureField` (id/label/systemImage/isFilled/`fill`), `WebFieldCaptureBar`,
   `WebExtractionOutcome`.

## Substrate note (resolve before building on it)

`WebExtractorBrowser` / `WebBrowserView` are built on **`WebPage` + SwiftUI `WebView`**
(ADR-0025) — confirmed in the moved source. Two related memories said earlier that
`WebExtractorBrowser` was still on `WKWebView` and that SwiftUI `WebView` wasn't in the
beta SDK; those are **stale** — the code is uniformly on `WebPage`+`WebView`. Any new
feature should build on `WebPage`+`WebView` too, not `WKWebView`.

## What "leverage the new browser" most likely means (candidates for the Codex order)

These are the already-identified next consumers (from the in-app-browser memory's
"NEXT EFFORT" list and ADR-0022 consequences) — pick/sequence when writing the prompt:

1. **Guide-link fallback consumer** — a modal `WebExtractorBrowser` whose `onExtract`
   runs `GuideLinkRecognizer` / `EvaluationRecognizers` → records evaluations, for the
   JS-heavy/paywalled guide pages the automated ADR-0021 fetch can't render. (Domain
   logic stays in galavant; the browser is just the renderer.)
2. **Browser as a top-level nav destination** (Jon asked 2026-06-25) — a "Browser"
   `AppScreen` case + sidebar/tab item to open the in-app browser directly, with a
   "capture this page" affordance running the capture pipeline
   (`CaptureModel`/`PlaceEnricher`) over the rendered DOM. *Note:* `BrowserScreen`
   already exists — confirm what's shipped vs. what's still wanted before scoping.
3. **Upgrade the automated fetch** — use headless `RenderedDOMFetcher` to give the
   share-extension / `PageFetcher` path a rendered-DOM fetch on miss (no UI).

→ **First step for the next session:** ask Jon which of these (or what else) the Codex
order should target. Don't assume; the phrase "leverage the new browser" is ambiguous
across these three.

## Constraints to bake into any Codex prompt

- **Branch + PR per slice; never push to main** (even trivial). Codex = executor: one
  draft PR per slice, green before ready, `question-for-architect` label when blocked.
  See jon-platform `docs/agent-collaboration.md`.
- **Parallel agents get separate git worktrees** — never share a checkout (memory).
- **Domain logic stays on galavant's side of the `onExtract` seam** — do not add app
  types to `WebExtractorKit`; that's the whole reason it's liftable. A genuinely
  reusable browser improvement goes into the jon-platform package (its own PR there);
  galavant-specific extraction goes in galavant.
- **Testability:** keep new extraction/recognizer logic as pure functions in
  `GalavantPlaces`/schema (tested), with the view a thin host — the app target itself
  isn't unit-testable (memory).
- **Verify on device, not just sim** for anything touching Apple Intelligence /
  `FoundationModels` (sim has none; `GalavantPlacesTests` already fails to `dlopen` it
  on the macOS host — unrelated to the browser, but don't get fooled by it).
- **Two-repo coupling:** galavant now needs a sibling `jon-platform` checkout. If a
  slice changes the package API, it's a coordinated change across both repos' PRs.

## Quick-verify the extraction (for the next session)

```sh
# package alone
cd ~/code/jon-platform/packages/WebExtractorKit && swift build && swift test   # 8 pass
# galavant app
cd ~/code/galavant/galavant && xcodegen generate && \
  xcodebuild build -project Galavant.xcodeproj -scheme Galavant \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'             # BUILD SUCCEEDED
```
