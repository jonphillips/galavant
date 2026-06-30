# Browser capture — feedback triage & remaining stages

Jon's feedback on the persistent in-app browser + tap-to-fill capture bar (ADR-0025 §5),
triaged into stages. Stages A and B are shipped; this doc carries the rest so any session
(or Codex) can pick them up cold.

## Status of the 12 feedback items

| # | Item | Stage | Status |
|---|------|-------|--------|
| 7 | Show full URL in the address bar | A | ✅ shipped `0ef6ee6` |
| 9 | Don't clear capsule values on Cancel; clear on navigation; highlight filled | A | ✅ shipped (highlight already existed; clear-on-any-page-change finished in C) |
| 10 | Show opening hours on the confirm sheet | A | ✅ shipped |
| 8 | Editable rating source name ("Guide" → "Michelin") | A | ✅ shipped |
| 2 | Update dropped notes / notes should be additive / notes-as-subhead | B | ✅ shipped (ADR-0026: `description` vs `notes`, additive notes) |
| 4 | Navigation/access note ("Apple Maps → wrong entrance") as a field | B | ✅ decided — lives in `notes`, no separate field (Jon's call) |
| 1 | Browser resets to Google when leaving & returning to the section | C | ⏭️ Codex next (brief below) |
| 6 | Hardware Return in the Google box flashes the sidebar, doesn't submit | D | 🅿️ punted — iOS 27 beta focus-routing bug (see KNOWN-ISSUES) |
| 5 | jan-hartwig.com cut off at the top of the screen | D | 🅿️ punted — per-site fixed-header quirk (see KNOWN-ISSUES) |
| 3 | das-achental `/en/` vs `/en/getting-here.html` capture different locations | E | 📝 investigation below |
| 11 | Some Michelin ratings are images, not text — capture via on-device LLM/Vision | F | 🔜 backlog (bigger) |

Shipped work lives on branch `feat/capture-bar-polish` (commit `0ef6ee6`), pending Jon's
review + merge to `main`.

---

## Stage C — Persistent browser session (hand off to Codex)

**Bug (#1):** In the iPad/Mac layout the detail is a single `NavigationStack` whose root
swaps by section selection (`Galavant/Navigation/AppContainer.swift`). `WebBrowserView`
(`GalavantLibrary/Sources/GalavantWeb/WebBrowserView.swift`) owns its live page as
view-local `@State` (`@State private var page = WebPage.browser(contentMode: .desktop)`).
Leaving Browser and returning reinstantiates `BrowserScreen`, recreates the page,
`page.url == nil`, and the `.task` reloads the start page (Google). Cookie/login
persistence is unaffected — only the in-memory page/nav state is torn down with the view.

**Fix (specified — no architectural decisions for the executor):** hoist the `WebPage` to
an object that outlives the screen view.

- **C1** `Galavant/Browser/BrowserScreenModel.swift`: add `let page = WebPage.browser(contentMode: .desktop)`.
- **C2** `WebBrowserView.swift`: delete the `@State` page; add `let page: WebPage`; add
  `page: WebPage` as the first parameter of BOTH initializers and assign it. `WebPage` is
  `@Observable`, so a plain `let` still drives view updates from `body` reads — no `@State`
  needed. The existing `.task` (load `initialURL` only when `page.url == nil`) is exactly
  right: a fresh page loads Google once; a returning page is left as-is.
- **C3** `Galavant/Navigation/AppContainer.swift`: add `@State private var browserModel = BrowserScreenModel()`
  (stable for the app's life) and inject it: `.environment(browserModel)` next to `.environment(router)`.
- **C4** `Galavant/Browser/BrowserScreen.swift`: replace `@State private var model = BrowserScreenModel()`
  with `@Environment(BrowserScreenModel.self) private var model`; add `@Bindable var model = model`
  at the top of `body` (needed for `.sheet(item: $model.capture)`); pass `page: model.page`
  to `WebBrowserView`.
- **C5** Now that the host owns the page, clear the capsule draft on **any** page change
  (covers in-page link taps that the explicit-only `onNavigate` misses): in `BrowserScreen`,
  `.onChange(of: model.page.url) { model.chipDraft = ChipDraft() }`. Remove the
  chip-clearing line from the `onNavigate` closure (this supersedes it); keep `onNavigate`
  itself if used for recents.

**Blast radius:** `BrowserScreen` is the only `WebBrowserView` caller; the headless DOM
fetcher uses `WebPage` directly and is unaffected.

**Acceptance gate (the bug only shows via the round-trip):** build, launch on the iPad Pro
13-inch (M5) sim, browse to a non-Google site + follow an in-page link, switch to Ideas,
switch back → still on that site with back history (not Google). Fresh launch still lands
on Google; capture still works.

**Process:** branch off `main` *after this batch is merged*, **in a dedicated git
worktree** (e.g. `git worktree add ../galavant-stageC <branch>`) — do not share the main
checkout with another agent. Commit `fix(browser): hoist WebPage so session survives
section switches`; PR into `main`.

---

## Stage D — Browser interaction / rendering polish

Both touch the browser view; do after C (which restructures page ownership). Needs
on-device/sim repro.

### D-6 — Hardware Return doesn't submit the address/search field

**Symptom:** with text typed in the address bar (e.g. a Google search), pressing Return on
the iPad hardware keyboard makes the **Browser** item in the sidebar flash but does not
navigate. The key event is being routed to the `NavigationSplitView` sidebar's list
selection instead of the focused `TextField`'s `onSubmit`.

**Where:** `WebBrowserView.swift` `addressBar` — the editing `TextField` has
`.submitLabel(.go)` + `.onSubmit(submitAddress)`. The submit isn't firing / is being
stolen.

**Likely fixes to try (in order):** confirm `@FocusState` is actually held by the field
when typing; ensure the `TextField` is inside a context where Return resolves to its
`onSubmit` rather than the split view's default action (may need `.onKeyPress(.return)` as
a fallback, or a focus-scoping change). Verify on device — hardware-keyboard focus routing
differs from the on-screen keyboard.

**Acceptance:** type a query, press hardware Return → the browser navigates; the sidebar
selection does not change.

**OUTCOME (2026-06-30) — PUNTED.** Verified on an iPad device (Xcode 27 beta). The
`.onKeyPress(.return) { submitAddress(); return .handled }` candidate did **not** help —
the field's key handler never wins; the Return still routes to the sidebar `List`.
Soft-keyboard "Go" works. Chalked up to an iOS 27 beta focus-routing bug and backed out
(branch `feat/browser-stage-d`, commit `9b27865`, deleted). Recorded in
`docs/KNOWN-ISSUES.md` with the focus-scoping fallback; re-check on later betas.

### D-5 — jan-hartwig.com clipped at the top of the screen

**Symptom:** the desktop-rendered page's fixed top nav is cut off above the visible area
(see Jon's screenshot). The browser renders at `.desktop` content mode; the site's sticky
header sits under the chrome / outside the safe area.

**Where:** `WebBrowserView.swift` body — `WebView(page).ignoresSafeArea(edges: .bottom)`
inside a `VStack` under the address bar + progress bar.

**Investigate:** whether the web content needs top safe-area / inset handling, or whether
`.desktop` content mode at panel width produces a viewport the site lays out for a taller
window. Compare `.recommended` vs `.desktop` for this site. May be a per-site quirk;
decide whether it's worth a general fix or accept it.

**Acceptance:** jan-hartwig.com's top nav is fully visible (or a clear decision that the
desktop trade-off is acceptable, documented here).

**OUTCOME (2026-06-30) — PUNTED.** Verified on an iPad device (Xcode 27 beta). The clip is
the **same in `.desktop` and `.recommended`**, so it is *not* the desktop-viewport layout —
the page's `position: fixed` header sits above WebKit's visible viewport top and scrolling
can't reveal it. Decided it's a low-value per-site quirk; capture is unaffected
(`currentDOM()` reads the full DOM regardless). Recorded in `docs/KNOWN-ISSUES.md`; revisit
top content-inset handling only if it turns out general.

---

## Stage E — Investigation

### E-3 — Two URLs of the same hotel capture different locations

`https://www.das-achental.com/en/` vs `https://www.das-achental.com/en/getting-here.html`
resolve to different places on capture. Likely the two pages carry different (or absent)
JSON-LD / `og` / address signals, feeding different Apple Maps match queries — or one page
has structured location and the other doesn't.

**How to investigate:** capture both pages' rendered DOM (the DEBUG match-diagnostics
section in `CaptureConfirmView` shows parsed title/locality/coordinate, the AI refinement,
the query, and the scored candidates — read it on-device for each URL and diff). Determine
whether it's "working as designed but surprising" (different pages legitimately describe
different things) or a parser/match-query bug. Note: das-achental was previously found to
be poorly indexed under its name in Apple Maps (see the persistent-browser memory), so a
manual-location fallback may be the realistic answer. Feed any fix into `PlaceMatching` /
`PageParser`.

---

## Stage F — Backlog (bigger, separate effort)

### F-11 — Image-based ratings (Vision OCR)

Some Michelin/guide ratings are images, not text, so the recognizers + text-only LLM miss
them. Add an on-device **Vision** OCR pass that feeds recognized text into the existing
`evaluationExtractor` path. Real feature; its own ADR/slice — not part of the browser
feedback batch.
