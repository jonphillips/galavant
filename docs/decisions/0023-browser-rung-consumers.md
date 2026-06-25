# ADR-0023: Browser-driven consumers of GalavantWeb — guide-rating fallback + capture-from-browser

*Status: accepted — 2026-06-25*

## Context

ADR-0022 extracted the app-agnostic `WebExtractorBrowser` (`GalavantWeb`) and wired
its **first** consumer — the "Find Hours" rung of the field-supplement ladder. It named
two more consumers and deferred both:

- **The guide-link fallback** (ADR-0021's explicit next rung): the automated guide-link
  hop in `PlaceEnricher.followingGuideLink` does a plain `URLSession` fetch of one
  recognized guide-detail link. That fetch fails on exactly the JS-heavy / consent-walled
  / anti-bot guide pages a rendered DOM fixes — so the ★★★ the page carries is never
  collected. The human-in-the-loop answer is to let the user drive `WebExtractorBrowser`
  to that guide page and run the evaluation recognizers over the rendered DOM.
- **The general "browse to any place, tap capture" entry point**: a top-level way into
  the in-app browser (not reachable only as a sub-affordance of an idea form), with a
  "capture this page" action that runs the existing capture pipeline over the rendered
  DOM.

Both are consumers of the same module; neither changes `GalavantWeb`. This ADR records
how they plug in, plus the one structural move the second requires.

## Decision

### 1. Guide-rating fallback — an idea-form affordance mirroring "Find Hours"

A new `GuideRatingSupplement` in `GalavantPlaces` is the judgments-sibling of
`FieldSupplement` (which owns *facts* — hours — and deliberately never writes
`IdeaEvaluation`). It exposes the same two-method shape the hours rung uses:

- `supplement(ideaID:)` — the cheap rung, re-run on demand: fetch the idea's own
  `url`, parse, `GuideLinkRecognizer.recognize` → first candidate, fetch **that** link
  via the shared `pageFetcher`, parse it with the guide URL as `sourceURL` (so the host
  `EvaluationRecognizers` fire), and record whatever evaluations it yields. Outcome:
  `.recorded(n)` when the plain fetch already renders, `.needsBrowser(url)` when it
  comes back empty (the JS-heavy case — open the browser *at the guide URL*), or
  `.noGuideLink` / `.notReady`.
- `applyBrowsedGuide(html:sourceURL:ideaID:)` — the rung-3 write-back: parse the DOM
  the user loaded in `WebExtractorBrowser`, record its evaluations, return the count.

The trigger surface is a **"Guide rating" section in `IdeaFormView`**, gated to a saved
idea with a link — the exact mirror of the hours section: a "Check guide page" button,
a status line, and a second `WebExtractorBrowser` sheet (`title: "Find Rating"`).

**Confidence stamping — `.official`, not `.unverified`.** Browsed *hours* stamp
`.unverified` because they come off an arbitrary page the user drove to. A browsed
*guide rating* is read by a **deterministic host recognizer off the recognized guide's
own page** — the identical rung the automated hop runs, only rendered. It is no less
authoritative for having needed a browser to render, so it carries the automated hop's
`.official`. The idempotent (source, kind, value) `IdeaEvaluation.record` (ADR-0019 §3)
keeps a rating the idea already has from doubling, whether it arrived automatically or
through the browser.

### 2. Browser as a top-level nav destination — a **modal extractor**, not a chrome browser

A new `AppScreen.browser` section shows a small **launcher** (an address/search field +
recent destinations). Choosing a destination presents `WebExtractorBrowser` **modally**
with `confirmLabel: "Capture"`. This reuses the ADR-0022 component *verbatim* — the
component is already a confirm-extract *session* (start URL → render → confirm → outcome
→ dismiss), which is exactly a capture.

We deliberately ship the modal extractor rather than a persistent browser screen with an
address bar and back/forward over a long-lived `WKWebView`. The persistent screen is a
better "browse around" experience but would require generalizing `GalavantWeb` to vend a
chrome-less reusable web view (plus app-side address-bar/navigation chrome) without
breaking its app-agnostic seam — strictly more surface for a v1 whose job is "land on a
place page and capture it." The modal's one real limitation — no in-browser address bar,
so changing destination means cancelling back to the launcher — is acceptable at
household scale and is the noted upgrade path (a future ADR-0022 amendment that exposes a
reusable web view).

**Capture-from-browser runs the full capture pipeline, including the confirm sheet.**
`WebExtractorBrowser`'s `onExtract` hands back `(html, sourceURL)`; the browser screen
stashes it and returns `.extracted` (dismissing the modal), then presents the **same**
`CaptureConfirmView` over a `CaptureModel(html:sourceURL:)` that the share extension
uses. That is what makes capture-from-browser honour the two laws this flow must obey:

- **Vet-at-source (M4c):** the user confirms name / location / trip / evaluations rather
  than a silent insert.
- **Dedup (ADR-0019):** `CaptureModel.prepare()` runs the Apple Maps match, resolves a
  `mapItemIdentifier`, and surfaces the "already in your pool — update it?" banner, so a
  page for a place already captured supplements the existing idea instead of duplicating
  it. Capture-from-browser is just another source feeding the *same* identity chain; no
  new dedup logic.

The app-side second hop (`PlaceEnricher`) then runs over the new idea exactly as it does
after a share capture — no new wiring.

### 3. Lift the capture confirm UI into a shared `GalavantCaptureUI` module

Reusing the confirm sheet in the app forces a structural move: `CaptureConfirmView` and
`LocationSearchView` live in the **`GalavantShare` extension target**, which the app
cannot import (an app embeds an extension; it doesn't link its code). Their imports are
already package-only (`GalavantPlaces` / `GalavantSchema` / MapKit / SwiftUI), so this is
a clean target move, not an untangle: both views move into a new **`GalavantCaptureUI`**
SPM module (the package's second UI module, after `GalavantWeb`). The extension and the
app then both depend on it — the extension is strictly better for the move (its confirm
UI is now shared, testable package code rather than target-private).

## Why this and not the alternatives

- **Why record browsed guide ratings as `.official`?** See §1 — same deterministic
  recognizer, same guide page, just rendered. Down-stamping to `.unverified` would
  understate a rating that is exactly as authoritative as the automated rung's.
- **Why not a persistent browser screen now?** See §2 — bigger `GalavantWeb` surface for
  marginal v1 value; modal reuse first, persistent later if the address-bar limitation
  bites.
- **Why the full confirm sheet for capture-from-browser, not a one-tap insert?** A silent
  insert would skip both vet-at-source and the ADR-0019 dedup banner — the two things
  capture exists to guarantee. Reusing `CaptureConfirmView` gets both for free.
- **Why a new module instead of duplicating the confirm view in the app?** Two copies of
  a 300-line confirm form drift. One shared module is the seam ADR-0022 already
  established for `GalavantWeb`; `GalavantCaptureUI` follows the same rule.

## Relationship to prior decisions

- **ADR-0021** (guide-link rung): this *is* its deferred HITL fallback — the rendered-DOM
  answer to the automated hop's plain-fetch failures. Reuses `GuideLinkRecognizer` and
  the host `EvaluationRecognizers` unchanged.
- **ADR-0022** (GalavantWeb): both consumers plug into `WebExtractorBrowser` with no
  change to the module; `GalavantCaptureUI` is the package's second UI module, following
  the same app-agnostic-seam discipline (it carries domain UI, deliberately — it is the
  app's, not a cross-app lift like `GalavantWeb`).
- **ADR-0019** (capture dedup): capture-from-browser feeds the same `mapItemIdentifier`
  identity chain; the idempotent evaluation record covers the guide-rating fallback.
- **ADR-0016** (source-aware capture): the guide-rating fallback reuses the
  `ParsedEvaluation` → `IdeaEvaluation` bridge and confidence model.
- **ADR-0006** (no version suffixes): `GalavantCaptureUI` is a plain domain name.

## Consequences

- `GalavantPlaces` gains `GuideRatingSupplement` (tested with a fixture fetcher +
  in-memory DB, like `FieldSupplement`); `IdeaFormModel`/`IdeaFormView` gain a "Guide
  rating" section mirroring hours.
- A new `GalavantCaptureUI` module holds `CaptureConfirmView` + `LocationSearchView`;
  `GalavantShare` imports it instead of owning them; the app imports it for
  capture-from-browser.
- `AppScreen` gains `.browser`; a new `BrowserScreen` launcher + modal `WebExtractorBrowser`
  + the shared confirm sheet deliver ADR-0022's deferred "browse to any place, tap
  capture."
- **Open:** the persistent-browser-with-address-bar upgrade (a reusable chrome-less web
  view out of `GalavantWeb`) is deferred until the modal's no-address-bar limitation
  proves worth the larger seam.
</content>
</invoke>
