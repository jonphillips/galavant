# ADR-0024: Headless rendered-DOM fetch for the automated enrichment paths

*Status: accepted — amended 2026-08-20*

## Context

ADR-0022 built `GalavantWeb` and its human-in-the-loop `WebExtractorBrowser` (rung 3
of the hours ladder), and **explicitly deferred** the unattended counterpart, noting:

> `WebPage` (present in the SDK) is a *headless* JS-rendering engine (`load` +
> `callJavaScript`, no view). It is the natural upgrade for the *automated* fetch
> paths … turn a raw `URLSession` fetch into a rendered-DOM fetch with no UI — closing
> the "raw fetch < rendered DOM" gap for the unattended case.

The automated paths are:
- `PlaceEnricher.pageFetcher` — the M4g second enrichment hop (re-fetch the place's own
  site) and the ADR-0021 guide-link follow.
- `FieldSupplement` rung 2 — the official-site opening-hours fetch.

Both use a plain `URLSession` GET. That GET fails on exactly the pages a rendered DOM
fixes: JS-rendered SPAs and anti-bot / consent-walled sites return an empty
`<div id="root">` shell whose parse yields nothing, even though the content is right
there once the page's JavaScript runs.

This ADR resolves the deferred item.

## Decision

### 1. Render-on-miss, not wholesale-replace

The cheap static `URLSession` GET runs **first**; a headless WebKit render is attempted
**only when that parse comes back empty**. Most pages carry JSON-LD / microdata that
parses statically; rendering is heavy (a separate WebContent process, seconds of
latency, real memory) and would buy nothing on those. Render-on-miss confines the cost
to the pages it actually fixes. The miss costs two fetches (GET + render); acceptable
because misses are the minority and the render is the only fetch returning content
anyway.

The "miss" predicate is **not a new magic threshold** — it reuses signals already in
the code:
- `PlaceEnricher` (main hop and guide-link follow): escalate when
  `ParsedPage.isEmpty` — the existing GalavantCapture predicate that already means
  "nothing useful found" (used at capture-confirm time). A page that *fetches* but
  parses empty is still returned, preserving the `enrichedAt` "fetched once → done"
  gate; `nil` (→ retry later) is reserved for a true fetch failure where no fetch
  returned anything.
- `FieldSupplement` rung 2: escalate when no hours resolved from the GET. This is
  narrower than `isEmpty` on purpose — a page can parse rich yet inject its *hours* via
  JS, and the rendered DOM carries the text both the deterministic parser and the
  on-device LLM (`hoursExtractor`) need.

### 2. The headless fetcher lives in `GalavantWeb`

`GalavantWeb.RenderedDOMFetcher` (`@MainActor`, WebKit-only, depends on no domain type
and no swift-dependencies) loads a URL in a viewless `WebPage` and returns the rendered
`outerHTML`. This **broadens GalavantWeb's charter** from "the interactive in-app
browser" to "rendered-DOM acquisition — interactive (`WebExtractorBrowser`) *and*
headless (`RenderedDOMFetcher`)." Both are "render a page's DOM via WebKit, know no
domain," so the headless fetcher lifts into the recipe app unchanged alongside the
browser (ADR-0022's cross-app reuse goal).

`GalavantPlaces` wraps it in an injectable `RenderedPageFetcher` dependency that mirrors
the existing `PageFetcher` exactly (same shape, same best-effort `nil`-on-failure
contract, `testValue` is `nil` so the escalation logic is tested with fixtures and no
WebKit). This adds a package-internal `GalavantPlaces → GalavantWeb` edge (no cycle —
`GalavantWeb` has no dependencies; the app already links both).

### 3. "Render complete" = the `.finished` navigation event — no speculative settle, no
new constant

`WebPage.load(_:)` returns `some AsyncSequence<NavigationEvent, Error>`. We iterate it
and break on `.finished` (main-frame navigation done), then read
`callJavaScript("return document.documentElement.outerHTML")`.

- **No fixed post-load sleep.** `.finished` is the signal. If a page needs more JS
  settling time, its re-parse comes back empty and we fall through cleanly
  (`FieldSupplement` → the HITL browser rung 3; `PlaceEnricher` → leaves the idea as
  captured, retryable). A speculative settle delay would be a guessed magic number with
  no evidence behind it — deliberately omitted; revisit only if real pages prove to need
  one.
- **No new timeout constant.** The network bound is `URLRequest`'s default
  `timeoutInterval` (60s) — *the same bound the existing raw `URLSession` path already
  lives under*. A hung load throws (timeout / `webContentProcessTerminated` /
  `invalidURL`) → `nil`, matching `PageFetcher`'s contract.

### 4. The share extension stays on the raw `URLSession` fetch — deliberately not upgraded

`GalavantShare`'s `fetchHTML` is a throwaway pre-fill for the in-extension confirm
sheet. The app re-fetches and re-enriches the same URL via `PlaceEnricher` (where the
rendered hop now lives), so rendering in the extension would be **redundant with the app
hop** — and would run WebKit under the extension's much tighter jetsam ceiling (well
below the host app's). The decisive argument is the redundancy, independent of the exact
memory number. Recorded here so a future reader doesn't "finish the job" by wiring the
rendered fetch into the extension.

## Amendment — effective URLs and image-specific misses (2026-08-20)

The automated fetch contracts now return the fetched document together with its
**effective final URL**. `URLSession` supplies it through `URLResponse.url`, and the
shared headless WebKit fetcher supplies `WebPage.url` after `.finished` (falling back
to the hygiene-upgraded request URL). Every automated parser uses that effective URL as
`sourceURL`, so relative images and guide links resolve against the page that actually
served the document. The canonical `Idea.url` remains the user's captured URL; writing
the effective URL back for canonicalization is out of scope.

The image refresh path has a narrower render-on-miss predicate than fact enrichment:
it renders when the static parse's `imageURLs` is empty, even when other facts such as a
title were found. The rendered parse is merged into the static parse, preserving useful
static facts while adding rendered image candidates. A static image hit keeps the cheap
path and skips rendering.

### SDK verification (past Claude's cutoff)

Verified against the Xcode-beta WebKit interface
(`…/iPhoneOS.sdk/…/WebKit.swiftmodule/arm64e-apple-ios.swiftinterface`,
`apple-sdk-headers-authoritative`):
- `@MainActor final public class WebPage`, `@available(iOS 26, macOS 26, …)`. The
  package's `platforms` already require 26, so **no `@available` gate or `#if`** — it
  compiles on the macOS `swift test` host (confirmed: the full package builds + tests
  green there).
- `func load(_ request: URLRequest) -> some AsyncSequence<NavigationEvent, any Error>`.
- `enum NavigationEvent { startedProvisionalNavigation, receivedServerRedirect,
  committed, finished }`.
- `func callJavaScript(_ functionBody: String, …) async throws -> sending Any?` —
  `functionBody` needs an explicit `return`.

## Consequences

- The unattended enrichment paths now reach JS-heavy / SPA / anti-bot pages that the
  raw GET left blank, at zero added cost on the static-parseable majority.
- `GalavantWeb` is now the home for *all* WebKit-backed DOM acquisition (interactive +
  headless); both pieces stay domain-free and lift to the recipe app together.
- The rendered fetch is injectable and `nil` in tests, so the render-on-miss escalation
  is fully unit-tested with fixtures; the live WebKit path is exercised on device.

## Relationship to prior decisions

- **ADR-0022** (in-app browser module): resolves its deferred "Future, not now"
  headless-`WebPage` note; broadens the `GalavantWeb` charter it established.
- **ADR-0016 §2** (field-supplement ladder): strengthens rung 2 with a rendered-DOM
  re-fetch before falling through to the rung-3 HITL browser; provenance unchanged
  (`.official`).
- **ADR-0021** (guide-link rung): the guide-link follow is now a render-on-miss path,
  the rendered-DOM answer to the automated hop's plain-fetch failures that ADR-0022
  anticipated.
- **ADR-0005** (native multiplatform): `RenderedDOMFetcher` is `WebPage`-based and
  multiplatform like the rest of `GalavantWeb`.
