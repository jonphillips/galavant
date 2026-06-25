# ADR-0022: GalavantWeb — an app-agnostic in-app browser module

*Status: accepted — 2026-06-24*

## Context

The human-in-the-loop browser (`HoursBrowserView`) is rung 3 of the field-supplement
ladder (ADR-0016 §2): when MapKit and a plain official-site fetch can't find opening
hours, Jon drives an in-app `WKWebView` to a page that has them — it renders JS, holds
a session, clears consent walls — then taps a button to run the parser over the
rendered DOM. The same "raw fetch < rendered DOM" need recurs for the guide-link rung
(ADR-0021): the automated hop's plain `URLSession` fetch fails on exactly the JS-heavy /
anti-bot / paywalled guide pages a rendered DOM fixes. So the browser wants to serve
*more than one* extractor — hours today, guide evaluations next.

`HoursBrowserView` is already structurally generic (a `startURL` + an `(html, url) ->
Bool` callback + load/grab/notice/dismiss machinery); only its strings and the
extractor are hours-specific. The BACKLOG sequenced generalizing it "with a real
driver, not a speculative general browser."

A second motivation makes the seam worth getting right: **the browsing capability will
be reused in a separate app (a recipe app).** So the *act of browsing* should be a
reusable unit a caller plugs an extractor into — not something with travel-domain
knowledge baked in.

## Decision

### 1. Extract an app-agnostic `WebExtractorBrowser` into a new `GalavantWeb` SPM module

`GalavantWeb` owns the **act of browsing** — load a URL, render JS, hold the session,
let the user navigate/clear consent, and on confirm scrape the rendered DOM
(`document.documentElement.outerHTML`). It hands that HTML + the current URL to an
injected plugin:

```swift
public enum WebExtractionOutcome: Equatable, Sendable {
  case extracted                 // caller got what it needed → dismiss
  case notFound(message: String) // nothing here → stay open, show message, user retries
}

public struct WebExtractorBrowser: View {
  public init(
    startURL: URL, title: String, confirmLabel: String,
    onExtract: @escaping (_ html: String, _ sourceURL: URL?) async -> WebExtractionOutcome
  )
}
```

The seam is **one-way**: the module depends on nothing but SwiftUI + WebKit and knows
no domain type (`Idea`/hours/guide). The caller depends on `GalavantWeb` *and* its own
domain modules and wires them together through `onExtract`. That's what lets the module
drop into the recipe app unchanged — the recipe app supplies a `{ html, url in
extractRecipe(html) }` plugin instead, and the browsing code doesn't move.

A **new module** (not a refactored view in the app target) is chosen deliberately: the
module boundary makes the seam *physical* — `GalavantWeb` literally cannot import a
domain type — so the cross-app lift is a target copy, not an audit-and-untangle. It is
the first UI module in the package (the others are pure logic); that's fine — its job
is reuse, and it carries no persistence/CloudKit/domain weight.

### 2. Built on `WKWebView`, multiplatform via a thin representable split

The SwiftUI `WebView` view (WWDC25) is **not present in the Xcode 27 beta SDK** —
verified against the SDK interfaces (`apple-sdk-headers-authoritative`): only the
`WebPage` model and the classic `WKWebView` exist. So the view wraps `WKWebView`.
`WKWebView` is unified across platforms; only the representable conformance is
`#if`-split — `UIViewRepresentable` under `canImport(UIKit)`, `NSViewRepresentable`
under `canImport(AppKit)` — plus `#if os(iOS)` around the iOS-only
`navigationBarTitleDisplayMode`. Everything else is shared SwiftUI.

The AppKit path is **not speculative**: the package declares macOS and the `swift test`
host *is* macOS, so the module must compile there regardless — and it makes the module
genuinely native-multiplatform, which the recipe-app-on-Mac goal wants. (The Galavant
app itself is iOS-only today and runs on Mac as the iOS binary, where the UIKit path
serves; a native macOS Galavant target, if it ever lands per ADR-0005, gets the AppKit
path for free.)

### 3. Consumers wire their own extractor

- **Hours (first consumer, this change):** the `IdeaFormView` sheet presents
  `WebExtractorBrowser(title: "Find Hours", …)` and supplies the existing
  `applyBrowsedHours` extractor, mapping its `Bool` to `.extracted` / `.notFound`.
  `HoursBrowserView` is deleted; behavior is unchanged.
- **Guide-link fallback (next consumer, ADR-0021's follow-on):** a flow that browses to
  a guide page the automated fetch couldn't render and extracts evaluations. Stacks on
  ADR-0021; out of scope for this change.

## Consequences

- One reusable browser; adding an extraction use case is a new `onExtract` plugin at a
  call site, never a new browser.
- `GalavantWeb` is liftable to the recipe app / a shared package with no rewrite — the
  physical module boundary guarantees no domain reference crept in.
- **Future, not now:** `WebPage` (present in the SDK) is a *headless* JS-rendering
  engine (`load` + `callJavaScript`, no view). It is the natural upgrade for the
  *automated* fetch paths (`PlaceEnricher`'s `pageFetcher`, the share extension) — turn
  a raw `URLSession` fetch into a rendered-DOM fetch with no UI — closing the
  "raw fetch < rendered DOM" gap for the unattended case. Deferred; noted so the next
  rung knows the tool exists.

## Relationship to prior decisions

- **ADR-0016 §2** (field-supplement ladder): this generalizes rung 3's browser; the
  hours behavior and `.unverified` stamping are unchanged.
- **ADR-0021** (guide-link rung): the deferred guide-link fallback consumer is the
  rendered-DOM answer to the automated hop's plain-fetch failures.
- **ADR-0005** (native multiplatform, not Catalyst): the AppKit path keeps the door
  open for a native macOS target without a browser rewrite.
- **ADR-0006** (no version suffixes): `GalavantWeb` is a plain domain-free name.
