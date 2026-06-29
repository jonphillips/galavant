# ADR-0025: Persistent in-app browser on `WebPage` + SwiftUI `WebView`

*Status: accepted — 2026-06-29*

## Context

ADR-0023 §2 shipped the Browser section as a **modal extractor**: a launcher (address
field + recents) that presents `WebExtractorBrowser` as a sheet, grabs the rendered DOM
on "Capture," and runs the shared `CaptureConfirmView`. It **explicitly deferred** the
richer alternative:

> the persistent-browser-with-address-bar upgrade (a reusable chrome-less web view out
> of `GalavantWeb`) is deferred until the modal's no-address-bar limitation proves worth
> the larger seam.

That limitation now bites, and two things have changed since:

1. **Product intent.** The browser should be a **full-screen, lived-in surface** in the
   detail panel — forward / back / refresh / stop and an editable URL bar — rendering at
   panel width so sites serve their **desktop** layout (the mobile layout is both uglier
   and, for capture, often thinner). It is a place to *browse to a source and capture
   it*, not a one-shot modal you cancel back out of.

2. **Authenticated capture is a first-class driver, not a nicety.** A persistent browser
   that **holds a logged-in session** reaches structured data that sits behind a paywall
   — the page embeds perfectly good schema.org markup, but an unauthenticated GET returns
   a teaser stub. This is the decisive requirement for the sibling recipe app (Yes Chef
   Phase D: a majority of its daily sites — NYT Cooking, Cook's Illustrated, ATK, Milk
   Street — are paywalled), and it applies to Galavant's own paywalled guide sources
   (Michelin, some city guides). It is an **authentication** problem, not an OCR/LLM one;
   owning the session end-to-end is the robust path.

3. **The SDK substrate decision flips.** ADR-0022 §2 built `WebExtractorBrowser` on the
   classic `WKWebView` *because the SwiftUI `WebView` was absent from the Xcode-27 beta
   SDK it checked*. That view is **now present** (iOS/macOS 26+, shipped in the
   `_WebKit_SwiftUI` cross-import overlay — see SDK verification below). It displays a
   `WebKit.WebPage` — the very `@Observable` engine `RenderedDOMFetcher` (ADR-0024)
   already drives headlessly. So the interactive browser can be the **same engine,
   *shown*** rather than a second WebKit stack.

This ADR resolves ADR-0023 §2's deferred item and corrects ADR-0022 §2's substrate
choice in light of (3).

## Decision

### 1. Adopt `WebPage` + `WebView(page)` as `GalavantWeb`'s single WebKit substrate

`WebKit.WebPage` is the `@Observable @MainActor` engine: `url`, `title`, `isLoading`,
`estimatedProgress`, `backForwardList`, `serverTrust`; `load` / `reload` / `stopLoading`
/ `callJavaScript`; a `Configuration { websiteDataStore, defaultNavigationPreferences,
urlSchemeHandlers }` and an optional `NavigationDeciding` for link/new-window policy.
The SwiftUI `WebView(_ page: WebPage)` renders it. This replaces the hand-rolled
KVO-`ObservableObject` web-view-store pattern entirely — Apple vends the observation.

`GalavantWeb` standardizes on this one substrate:

- **`RenderedDOMFetcher`** already uses `WebPage` headlessly (load with no view → read
  `outerHTML`). Unchanged.
- **`WebExtractorBrowser`** (the modal extractor; consumers: the "Find Hours" and
  "Find Rating" idea-form rungs) is **migrated off `WKWebView` onto `WebPage` +
  `WebView`**, deleting its `UIViewRepresentable`/`NSViewRepresentable` split. Behavior
  is unchanged — same start-URL → render → confirm → `WebExtractionOutcome` session,
  same `callJavaScript("return document.documentElement.outerHTML")` grab — it simply
  rides the shared engine. The in-form rungs stay modal; only their plumbing changes.

Result: interactive (*shown*) and headless (*viewless*) DOM acquisition are one engine —
the literal fulfillment of ADR-0024's broadened "rendered-DOM acquisition, interactive
**and** headless" charter, and the cross-app substrate the recipe app harvests.

### 2. A reusable, domain-free `WebBrowserView` (chrome) in `GalavantWeb`

`GalavantWeb` gains a complete persistent browser view over an `@State WebPage`:

- **Chrome:** an editable URL/search bar (edit ↔ display toggle), back / forward /
  refresh / stop, and a determinate progress bar bound to `page.estimatedProgress`.
  Back/forward derive from `page.backForwardList` (`canGoBack = !backList.isEmpty`;
  navigate via `load(item)`); stop is `stopLoading()`.
- **Desktop by default:** `Configuration.defaultNavigationPreferences.preferredContentMode
  = .desktop` — the panel-width desktop layout the product wants.
- **No nested `NavigationStack`.** The iPad split-view detail column already owns one
  (nesting traps it — the standing trap). The chrome is a custom top bar + bottom toolbar
  in a `VStack`, not a second navigation bar.
- **App-agnostic, with an injected accessory seam.** The view knows no domain type
  (depends only on SwiftUI + WebKit). The host supplies its app-specific affordances —
  the "Capture" action today, the field-capture bar later — through a bottom-accessory /
  extraction closure, the same one-way seam ADR-0022 established (`onExtract(html,
  sourceURL)`). That is what lets the whole browser drop into the recipe app: it supplies
  a recipe extractor and accessory; the browsing code does not move.

### 3. `BrowserScreen` becomes the persistent panel host

The app's `BrowserScreen` drops the modal launcher and renders `WebBrowserView` directly
in the detail column:

- **Home / start state:** the existing lightweight recents (`@Shared(.appStorage)`,
  capped) plus a search prompt, shown when no page is loaded; the URL bar navigates away
  from it. No bookmarks model (the captured ideas are the real record — recents are a
  convenience, per ADR-0023). Recents persistence is unchanged.
- **Capture:** a bottom-bar action pulls the rendered DOM
  (`page.callJavaScript("return document.documentElement.outerHTML")`) and presents the
  **same** `CaptureConfirmView` over `CaptureModel(html:sourceURL:)` the share extension
  and the modal extractor use. This preserves the two laws capture must obey
  (ADR-0023 §2): **vet-at-source** (M4c) and **dedup** (ADR-0019 — the Apple Maps match +
  "already in your pool — update it?" banner). The browser **stays put** after capture
  (it is persistent, not a dismissing modal). The app-side second hop (`PlaceEnricher`)
  then runs over the new idea exactly as after any capture — no new wiring.

### 4. Authenticated / paywalled capture: the default persistent session, never ephemeral

The session is the whole value: log in once, capture many times, across launches.
`WebPage()` and `WKWebView()` both default to the persistent `WKWebsiteDataStore`, so
cookies/login already survive relaunch; Galavant uses **no** ephemeral store anywhere,
and this ADR makes that a **rule**: the browser's `WebPage.Configuration` keeps the
default persistent `websiteDataStore` — never a non-persistent one, or paywall logins
would not persist. Credentials are never stored by the app; the session lives only in the
web view's own data store.

### 5. Deferred: the tap-to-fill field-capture bar (seam designed, not built)

The richest future affordance — a bar of field chips (Name / Hours / Address / …) that
fill from an on-page text selection, as the first Galavant prototype had — is **out of
scope here**. But the substrate is chosen so it is a clean add: `WebView` exposes
`webViewTextSelection` and `webViewOnScrollGeometryChange`, and `WebPage.callJavaScript`
can run a selection-reporting user script. Phase 1 lands the browser + desktop mode +
whole-page capture; the field bar is a later phase on this same engine.

## Why this and not the alternatives

- **Why `WebPage`+`WebView` over staying on `WKWebView`?** The SwiftUI view now exists,
  is the same engine as the headless fetcher (one substrate, not two), gives observation
  for free (no KVO store), and is native SwiftUI (no representable). ADR-0022's
  `WKWebView` choice was correct *for an SDK without the view*; that condition no longer
  holds.
- **Why migrate the modal extractor too, not just add the new browser?** Two WebKit
  substrates in one small module is avoidable debt; the modal's behavior is unchanged and
  its package tests guard the migration. One engine keeps the cross-app lift a clean copy.
- **Why a persistent panel, not the modal we shipped?** The modal's no-address-bar
  limitation is exactly the friction ADR-0023 §2 said would justify this upgrade, and a
  persistent logged-in session is required for paywalled capture — which a present-then-
  dismiss modal cannot hold across captures.
- **Why recents, not bookmarks?** Unchanged from ADR-0023: the captured ideas are the
  record; a synced bookmarks model is weight the household scale does not need yet.
- **Why keep the full confirm sheet for capture?** Unchanged from ADR-0023 §2: a silent
  insert would skip vet-at-source and the ADR-0019 dedup banner — the two guarantees
  capture exists for.

## SDK verification (past Claude's cutoff)

Verified against the iOS 27.0 SDK (Xcode-beta 27A5209h), per
`apple-sdk-headers-authoritative`:

- **`WebView` exists** — `_WebKit_SwiftUI` cross-import overlay (auto-loaded when a file
  imports both `SwiftUI` and `WebKit`), at
  `…/iPhoneOS27.0.sdk/System/Cryptexes/OS/System/Library/Frameworks/_WebKit_SwiftUI.framework/…`
  (**not** under plain `System/Library/Frameworks`, which is why ADR-0022's check of the
  base SwiftUI/WebKit interfaces missed it). Signature:
  `@available(macOS 26.0, iOS 26.0, visionOS 26.0, *) @MainActor public struct WebView:
  View { public init(_ page: WebPage); public init(url: URL?) }`, with modifiers
  `webViewBackForwardNavigationGestures`, `webViewMagnificationGestures`,
  `webViewTextSelection`, `webViewContextMenu`, `webViewScrollPosition`,
  `webViewOnScrollGeometryChange`, …
- **`WebPage`** (`@MainActor final class`, iOS/macOS 26+): observable `url` / `title` /
  `isLoading` / `estimatedProgress` / `backForwardList` / `serverTrust`; `load` /
  `reload(fromOrigin:)` / `stopLoading()` / `callJavaScript(_:arguments:in:contentWorld:)`;
  `init(configuration:navigationDecider:dialogPresenter:)` overloads;
  `Configuration { websiteDataStore, defaultNavigationPreferences, urlSchemeHandlers }`;
  `NavigationPreferences.ContentMode = .recommended / .mobile / .desktop`.

The package's `platforms` already require 26, so **no `@available` gate or `#if`** — the
module compiles on the macOS `swift test` host (where `RenderedDOMFetcher` already builds
green on `WebPage`).

## Relationship to prior decisions

- **ADR-0022** (GalavantWeb module): resolves its deferred persistent-browser note and
  **corrects its §2 substrate choice** — `WebPage`+`WebView` now that the SwiftUI view
  exists; the app-agnostic one-way `onExtract` seam is preserved and extended to the new
  `WebBrowserView`.
- **ADR-0023** (browser-driven consumers): delivers the §2 "Open" item (persistent
  browser with address bar); the modal extractor's consumers (Find Hours / Find Rating)
  keep working, re-platformed onto `WebPage`; capture-from-browser keeps the vet-at-source
  + ADR-0019 dedup path.
- **ADR-0024** (headless rendered-DOM): unifies onto its `WebPage` engine — interactive
  (shown) and headless (viewless) are now one substrate, the literal "interactive *and*
  headless" charter it named.
- **ADR-0019** (capture dedup): capture-from-browser feeds the same `mapItemIdentifier`
  identity chain; unchanged.
- **ADR-0005** (native multiplatform): `WebPage`/`WebView` are multiplatform; the AppKit
  representable in `WebExtractorBrowser` goes away (SwiftUI `WebView` is cross-platform),
  keeping the door open for a native macOS target with less platform-split code.
- **ADR-0006** (no version suffixes): `WebBrowserView` is a plain domain-free name.

## Consequences

- `GalavantWeb` runs on **one** WebKit substrate (`WebPage`); the `UIViewRepresentable`/
  `NSViewRepresentable` split is deleted. The module is the home for interactive +
  headless DOM acquisition, both liftable to the recipe app together.
- The Browser section becomes a persistent, desktop-rendering, **session-holding** browser
  that reaches paywalled structured data; capture from it stays within the shared confirm
  + dedup pipeline.
- The field-capture bar is a clean future phase on the same engine (text-selection +
  user-script seams noted).
- **Open / next:** the tap-to-fill field-capture bar (ADR-0023's manual-extraction idea),
  scoped as a follow-on once the persistent browser lands.
