# Handoff: M9 — Recommendation evaluation workspace (ADR-0037)

Build the surface that processes a returned candidate **set** like an inbox:
a candidate **rail**, a **map**, and a **browser** (browser primary), with exactly
one candidate always selected. Selecting drives map + browser; **Use This Place**
resolves a fuzzy AI suggestion into trustworthy Galavant data while preserving the
AI's trip rationale; survivors graduate into Ideas or the itinerary.

This brief turns [ADR-0037](../decisions/0037-recommendation-evaluation-workspace.md)'s
Slice 1–4 into an executable plan. **Read ADR-0037 in full first** — it is the source of
truth; this brief only pins seams, ordering, and the pure/impure split. ADR-0037 stands on
[ADR-0036](../decisions/0036-recommendation-handoff.md) (the handoff *substrate*), which is
its own handoff.

---

## Hard ordering (do not start ADR-0037 before this is true)

ADR-0037 is the **surface** over ADR-0036's **substrate**. It cannot begin until the
substrate ops it calls exist:

| ADR-0037 phase | Blocks on ADR-0036 |
| --- | --- |
| Phase 1 (rail + selection) | Slice 1 — the handoff record + candidates committed as `.considering` `TripIdea`s, plus the Save/Dismiss ops |
| Phase 2 (map + Use This Place) | Slice 2 — the resolve-via-capture op and "choose one" → ring |
| Phase 3 (browser + write-back) | Slice 2 — resolution state (needed to derive the browser target) |
| Phase 4 (iPhone) | — (presentation only) |

So the milestone sequence is **ADR-0036 S1 → ADR-0037 P1 → ADR-0036 S2 → ADR-0037 P2/P3 →
ADR-0037 P4**. ADR-0036 S3 (the lift) is decoupled — see the OQ2 resolution (copy-then-lift):
Galavant ships on a **local** spine; the lift is a later, separate PR that does not gate this
work.

**One PR per phase** (four PRs), or bundle P1+P2 if S1/S2 of ADR-0036 land together — but
never let P3's browser targeting merge before P2's resolution state exists, or the target
derivation (D5) has nothing to key off.

---

## Shared context (read first)

Repo: galavant (V3) at `~/code/galavant/galavant`. Household iOS app, SwiftUI,
SQLiteData+CloudKit, no server, Point-Free style **without** TCA. Read `AGENTS.md` +
`CLAUDE.md` first. Conventions that will bite you:

- **Branch + PR workflow:** never push to main. Feature branch, open a PR.
- **Work in your OWN git worktree** (do not share the main checkout). Building from a
  worktree fails to resolve local SPM packages until you add this symlink:
  ```
  ln -s /Users/jon/code/jon-platform <worktree>/galavant/.claude/jon-platform
  ```
- **XcodeGen-managed project:** `project.yml` is source of truth, `project.pbxproj` is
  generated AND tracked. New `.swift` file → `xcodegen generate`, commit BOTH. Every package
  product a target imports MUST be declared in `project.yml` deps or regenerate drops the link
  (Undefined symbols). Editing existing files needs no regenerate.
- App builds with `-skipMacroValidation` (macro trust may need re-approval in Xcode).
  `swift test` aborts here (FoundationModels host gap). Run schema tests by temporarily
  disabling FM-linked test targets; **none of the pure core below touches FoundationModels**,
  so it is testable in isolation — put it there deliberately.
- **The app target is effectively untestable** (no app unit-test bundle, UI tests can't reset
  the DB). Therefore: **all traversal/selection/decision logic lives in the GalavantSchema
  functional core as tested value types**, NOT in the feature model (`watch-for-fat-models`).
  The `@Observable` workspace model is a thin shell that owns live UI state and calls the core.
- Layout gate everywhere: `usesColumn = horizontalSizeClass == .regular` (iPad).
- **iPad detail is a nested-navigation trap:** do NOT nest a `NavigationStack` in the iPad
  split detail (pushes pop). Use overlay/panel swaps for in-panel drill-downs. This directly
  governs P3 (browser) and P4 (iPhone push).
- Match surrounding comment density/idiom. No version suffixes in identifiers (ADR-0006).
- Install/launch review builds on the **iPad Pro 13-inch (M5)** simulator.

### Seams you will reuse (locate, don't rebuild)

- **TripIdea + status:** `GalavantLibrary/Sources/GalavantSchema/TripIdea.swift`,
  `TripIdeaStatus.swift` (`.considering = 0`, `.shortlisted = 1`). Candidates are freeform
  `TripIdea`s (`ideaID == nil`, `inlineTitle` = model name, rationale in `inlineNote`).
- **Alternatives ring ops (ADR-0035):**
  `GalavantLibrary/Sources/GalavantSchema/TripIdea+Alternatives.swift` — `alternativeGroupID`
  grouping already exists and is tested. "Choose one" reuses this; do not add a new relation.
- **Capture merge / dedup (Use This Place):** `GalavantSchema/IdeaMerge.swift`,
  `GalavantPlaces/PlaceMatcher.swift`, `GalavantCaptureUI/CaptureConfirmView.swift`. Use This
  Place is the region-biased `MKLocalSearch` + confirm-merge with a candidate as its seed —
  reuse the existing flow; it already sets `ideaID`, dedupes via `mapItemIdentifier`, and
  harvests name/coords/address/category/`url`.
- **Persistent browser + field-capture bar (ADR-0025):** `Galavant/Browser/BrowserScreen.swift`,
  `BrowserScreenModel.swift`. The browser is `WebView(WebPage)` (iOS 26+ overlay), not
  `WKWebView`. Field-capture write-back (D5) is this bar pointed at a resolved place.

---

## Phase 1 — Rail + selection over the set (no map/browser yet)

**Goal:** the three-pane scaffold with a working candidate rail and the always-one-selected
inbox loop, proven end-to-end on the simplest surface. Save/Dismiss work; no map, no browser.

**Pure core (GalavantSchema, test-first) — build this before any view:**
Add a value-type traversal core (e.g. `CandidateSetTraversal`) over the handoff set:
- `active` is **total over a non-empty set** — there is never a "nothing selected" state
  (ADR-0037 D1); selecting is a pure function.
- `next(after:)` / canonical ordering — what becomes active after one leaves the queue.
- `dismiss` / `save` remove-and-reselect **deterministically** (ADR-0037 D2/D6).
- An unresolved candidate is a **valid saved state** (Save = `.considering` → `.shortlisted`,
  no `ideaID` — ADR-0036 D3; only resolution mints a pool `Idea`).
Unit-test all of it in-memory with fixtures. This is the part that must not live in the model.

**View / model:**
- Thin `@Observable` workspace model holding `activeCandidateID` + the handoff-set query;
  delegates traversal to the core.
- Three-pane iPad scaffold (rail · map-placeholder · browser-placeholder), browser-weighted
  stage. Rail cards show name, AI **why**, fit, rough time, resolution status, actions.
- **Save to Ideas** → shortlist op (ADR-0036 Slice 2 / D6). **Dismiss** → delete the
  `.considering` `TripIdea` with standard undo (D6) — no "dismissed" status column.
- **Entry point (ADR-0037 OQ4):** decide alongside ADR-0036's paste door. Recommended: a
  banner/section on the Trip (and Ideas) screen that opens the workspace for the most recent
  unimported handoff, plus a direct push from the paste-review sheet. Confirm at dispatch.

**Verify:** schema tests green (traversal total/deterministic; unresolved-saved valid); one
elevated iOS build; install on iPad Pro 13" — open a set, select down the rail, save two,
dismiss one (undo), reopen and confirm progress persisted (state is the handoff record +
`TripIdea` status, ADR-0037 D2, no new table).

---

## Phase 2 — Map layers + Use This Place

**Goal:** the three-layer map and the resolve gesture; a resolved candidate carries both
trustworthy place data and the preserved AI rationale.

**The map is three distinct layers (ADR-0037 D3) — conflating them builds it wrong:**
1. Itinerary geography (existing stops + lodging) — drawn as usual.
2. The candidate's **fuzzy marker** (approximate `locality`) — active emphasized, rest muted
   (reuse ADR-0035's muted/emphasized pin language).
3. **Resolve results** — transient `MKMapItem`s shown *only* during Use This Place.
"Tap a candidate → highlight" = layer 2 before resolution, the confirmed pin after. Never
silently invent a precise location.

**Use This Place (D4):**
- Auto-run the region-biased `MKLocalSearch` from `search_hint` + `locality`, biased by the
  trip/stay region (the ADR-0016 matcher — reuse, do not fork).
- Tapping the correct `MKMapItem` runs the existing confirm-merge (`IdeaMerge` / ADR-0019):
  mints/links the pool `Idea`, **dedupes** onto an existing one, sets the candidate's `ideaID`,
  harvests facts.
- **Two-layer preservation is structural:** facts → shared `Idea`; AI rationale stays on the
  trip-scoped `TripIdea.inlineNote`. Resolution sets `ideaID` and **never touches the
  rationale** — assert this in a schema test.
- Ambiguity/no-match degrade: several → human picks; none → stays unresolved and still useful.
- "Choose one" group → alternatives ring via `TripIdea+Alternatives.swift` (ADR-0035).
- Resolution status shows in the rail (unresolved · resolved).
- **Resolve-time reconcile (ADR-0037 OQ5) — settle here.** Confirm-merge dedupes at the pool
  `Idea` level but leaves **two `TripIdea` rows in one trip** if the resolved place is already
  shortlisted/scheduled (the "Louisiana Museum of Art in both Shortlist and Considering" case).
  Resolution is the first moment the candidate has an `ideaID` to key on. Lean: **warn and let
  the human choose (merge / keep both), defaulting to merge** — folding the candidate rationale
  into the existing row, preserving both `inlineNote`s (IdeaInterest merge precedent in
  `PoolOperations`). Decide the default from a real set; this is the dedup question the paste
  door structurally can't answer.

**Verify:** schema test for two-layer preservation (resolution sets `ideaID`, rationale
untouched) + dedup-onto-existing; device pass — locate, Use This Place on a real return, watch
it dedupe onto a known place.

---

## Phase 3 — Browser + write-back

**Goal:** the state-driven browser target and the enrichment write-back.

- **Target derivation (D5), AI never supplies the URL:** before resolution → a **web search
  from `search_hint`**; after resolution → the resolved `Idea`'s `MKMapItem.url`.
- Selecting a candidate **auto-loads** its target, **lazily** (skimming pure geography down
  the rail must not be heavyweight).
- **Field-capture write-back:** if a better official URL is found while browsing, the
  ADR-0025 §5 capture bar writes it back to the resolved `Idea` ("Use this website for …").
- Navigating in the browser does **not** change the active candidate (selection is model
  state, the URL is just where you are).
- **Add to itinerary (D6):** allowed unresolved → freeform stop (ADR-0010); resolving later
  **upgrades** it to a normal pulled stop. "Resolve before it's a normal stop" is a **soft UI
  nudge, not a hard gate.** A `placement_after` hint is advisory, human-confirmed (ADR-0036 D6)
  — never a silent slot write. "Choose one" promotes as a ring.
- **iPad nested-nav trap applies:** the browser is a panel/overlay swap in the detail, not a
  nested `NavigationStack`.

**Verify:** device pass — before/after-resolution target switch; write back a URL and confirm
it lands on the `Idea`; add unresolved to itinerary then resolve and see the upgrade.

---

## Phase 4 — iPhone presentation

**Goal:** the sequential layout over the **identical** model (ADR-0037 D7) — same candidate
state and processing loop, layout only changes.

- **Home** = map + candidate **sheet** (rail as a bottom sheet). Locating and **Use This Place
  happen here**, on the map.
- **Browser** is **pushed/presented** for research and dismissed back to the *precise* same
  active candidate — because selection is feature-model state, not a navigation entry (this is
  the nested-nav pop trap; keep selection in the model).
- No new logic — if Phase 4 needs core changes, the P1 core wasn't general enough; fix the core.

**Verify:** device pass on iPhone — full loop (select → research → Use This Place →
save/add/dismiss), background and resume mid-set, confirm the active candidate survives a
browser round-trip.

---

## Open questions to settle at dispatch (from ADR-0037)

- **OQ1 — rail pacing affordance.** Tap-to-select only, or explicit next/skip (iPad keyboard)?
  Decide from the first real set's size in dogfooding. Ship P1 with tap-only; revisit.
- **OQ2 — map result confidence UI.** Auto-highlight top match, require the tap (lean). Confirm
  on device in P2.
- **OQ3 — set clutter at scale.** Muted-non-selected pins may suffice; fallback is a
  "selected + neighbors only" filter. Assess with a real 12-candidate dossier.
- **OQ4 — workspace entry point.** Decide at P1 alongside ADR-0036's paste door (see Phase 1).
- **OQ5 — resolve-time reconcile (intra-trip dupe).** Settle in P2 (see Phase 2 / ADR-0037
  OQ5). The paste door can't answer it (unresolved candidates carry no place identity); Use
  This Place is where it belongs. Lean warn-and-choose, default merge.

## Definition of done (all phases)

Schema tests green (traversal core + two-layer preservation); one elevated iOS build per PR;
device pass for the real loop — open a returned set, select, research, Use This Place,
save/add/dismiss, resume after backgrounding. **No synced entity, no second ingestion path**
(ADR-0036) — if a phase reaches for either, stop and flag it.
