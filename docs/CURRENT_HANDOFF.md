# Current Handoff — what's next

Open work only: on deck, in progress, blocked, or designed-but-not-built. Shipped
work lives in `docs/DONE_LOG.md`; milestone framing in `docs/ROADMAP.md`; the
rationale for anything below is in its ADR (`docs/decisions/`). If an entry here is
done, delete it — don't let it rot (this file is the single source for what's
*open*, per house rule "status lives in docs").

Rough order: active first, blocked/designed next, verification gates and provenance
last. Not a strict priority queue — each entry stands alone enough to act on cold.

_Last swept 2026-08-23: ADR-0045 fully shipped — WS2 candidate display anchors (#97)
and WS3 Evaluate map reuse of `PlaceSelectionMap` (#98) landed on top of WS1 (#93),
so the whole Evaluate-geographic-model section retired to `DONE_LOG.md`. Prior sweep
(2026-08-22) removed everything shipped through PR #94 (StopMenu declutter #74–78,
calendar-constraint promotion #71, stable travel modes #69, M7 dogfood #57,
Accommodations #68/#81, travel-graph one-pass #83, Ideas-map POI exploration #91,
richer stop detail #63/#64, alignment-review items). Historical M6/chat/portfolio
framing collapsed to pointers._

## Active — paste on the Evaluate candidate strip (queued for Codex)

The candidate strip has an image **drop** zone (#92) but no paste, while the Idea
editor already offers Photos + paste + drop (#56). Add a `PasteButton(supportedContentTypes:
[.image])` beside the drop well in `RecommendationWorkspaceImageDropWell`
(`Galavant/Trips/RecommendationWorkspaceView.swift`), reusing the existing
`droppedImage(from:)` loader and the `model.attachDroppedImage` sink, gated the same as
`canAcceptDrop`. Covers iPhone / one-handed / no-split-view, where drag fails. Prompt
written; Jon to release to Codex.

## Active — plan-memoization follow-up (awaiting approach sign-off)

The itinerary lockup was fixed by lifting mode resolution into one pass
(`TripPlan.legModes`, shipped #83). The remaining hazard: `TripPlanningModel.plan` /
`itinerary` / `legIdentities` still rebuild on every view-tree access. Memoize the
planning read model so it isn't recomputed per access. Measurement + two invalidation
designs are in [`docs/handoff/plan-memoization.md`](handoff/plan-memoization.md),
awaiting Jon's sign-off on the approach before build.

## Active — M9 cockpit polish + yes-chef adoption (post-ship follow-ups)

M9 (recommendation handoff + evaluation cockpit) and the LLMHandoffKit lift shipped and
are dogfooded (`docs/DONE_LOG.md`). Remaining, non-blocking:

- **Choose One day-anchoring.** Marking 2+ candidates + Choose One builds an
  alternatives ring (ADR-0035), but the ring is dayless/`.considering`, so it never
  appears on the itinerary. Commit the ring **to a day** at creation (born scheduled).
- **Dossier flyover (cockpit Slice 3).** The focused candidate card should expand *over*
  its siblings to reclaim their width; it currently expands inline and pushes them right.
- **iPhone cockpit layout (cockpit Slice 4).** The compact layout still uses the
  pre-cockpit candidate rail/sheet; give it the same candidate state in a map-first sheet
  + pushed browser.
- **yes-chef adoption of LLMHandoffKit** (ADR-0036 consumer #1). yes-chef has an
  equivalent handoff spine; converging it onto the shared jon-platform package is its own
  repo/PR (like the WebExtractorKit lift's still-open yes-chef rewire).

## Blocked (Xcode 27 beta) — cross-day itinerary drag + sectioned inline reorder

Within-day drag-to-reorder ships (#72; `dayRank` for Anytime stops per ADR-0033). Two
related next steps are blocked on the beta's DnD subsystem:

- **Drag stops across day sections** and **out of the "To Be Scheduled" bucket onto a
  day** — same gesture: drop target → day number → `TripIdea.schedule(.onDay(n))` /
  `scheduleUnplaced`. Needs cross-section drag (single-collection `reorderable()` can't).
- **Sectioned inline reorder** — render day-anchored rows (hotel/calendar/home-base/now)
  inline at their time position and drag events between days, via the
  `reorderContainer(for:in:)` overload.

Both need the sectioned reorder overload, **recorded dead on beta 5** (#73). Full spec
with the two paid-for gotchas (no custom `dragContainer`, no long-press `.contextMenu` in
a reorderable row) and a spike-first plan:
`docs/handoff/sectioned-reorder-inline-boundaries.md`. Durable fallback if reorder stays
broken: render the itinerary as `ScrollView`/`LazyVStack` instead of `List`. See
`docs/KNOWN-ISSUES.md`; menus cover the function meanwhile.

## Designed / deferred (product)

- **Trip header image — "romance" (ADR-0032).** The schema landed (`headerImageURL` +
  color + photographer columns on `Trip`, hotlinked Unsplash reference, no BLOB/FK, no
  sync registration). **Open:** confirm the picker + placement actually shipped end-to-end
  (ADR still marked *proposed*; injectable `UnsplashClient`, `registerDownload` +
  attribution per ToS). Placement call: hero band atop the detail panel (the map-first
  canvas has no title area). Distinct from region "romance" photos (#54, ADR-0040).
- **Multi-select tag picker (Jon, 2026-06-13).** The model supports many tags per idea
  (`IdeaTag`), but the form adds them one at a time. Want a multi-select picker (a
  dedicated push-from-form screen is fine): a scrollable list of all tags with
  checkmarks, toggle several at once, keep type-to-create. Likely reuses TagManagerView's
  list shell; the inline one-at-a-time add stays as the quick path.
- **Itinerary completion rollup (Jon, 2026-06-13).** Completion should be *inferred*, not
  tapped: once a trip's day/time passes, flip its non-skipped scheduled ideas'
  `visited` (the done→visited loop, ADR-0004, moved from per-stop to trip-level). The
  `TripIdea.markDone` op + test exist; only the trip-level trigger is unbuilt.
- **Consolidate remaining management UIs into Settings.** A Settings area now exists
  (region management, sync health, AI, travel profile). Still to migrate off the filter
  menu: **tag management**, and **planner identity / switching** when that lands.
- **Planner identity strengthening (Jon, 2026-06-12).** The name-only "Who are you?"
  prompt is flimsy. Direction (ADR-0008 "future"): derive identity from the accepting
  Apple ID (unique key + name/email when consented), `displayName` as editable override.
  Blocked on the M5 real-device share-accept flow. Cheap interim: optional typed
  `email`/subtitle on `Planner` for picker disambiguation.

## Engineering discipline / small follow-ups

- **UUID dependency-control for new schema ops.** Existing ops call `UUID()` directly
  (`TripOperations`, `PoolOperations`, `Tag`, `TripRegion`, `IdeaTag`). Don't churn
  working code, but *new* vertical slices should accept IDs as args (model supplies a
  `@Dependency(\.uuid)`).
- **ADR-0008 TravelParty follow-ups.** Sync-dedup hardening shipped (#20). Still open:
  (1) real two-device dogfooding of the TravelParty merge (deletes party rows + repoints
  children; only manifests on a genuine offline race); (2) `Planner.create`
  planner-level dedup — merging two *populated* parties repoints blindly and can leave
  duplicate planners/tags (extreme edge; merge-with-dup beats data loss). Adjacent to
  planner-identity above.
- **jon-platform shared-doc refinements.** Five cross-app rules from the 2026-06-16
  alignment review (displayed-collection delete/reorder; split-view nested-NavigationStack;
  UUID-generation nuance; one-shot-read cancellation; `-skipMacroValidation` CLI note)
  belong in `~/code/jon-platform`, not here — apply there.

## Verification gates (decision gates, not a build queue)

- **M5 real-device gate.** TestFlight on both phones: travel-party share acceptance,
  two-way CloudKit changes, image/BLOB round-trips, pinned-reservation behavior.
  Checklist: `docs/M5-EXECUTION.md`. (The old "manual Calendar export on both devices"
  check was dropped per ADR-0034.)
- **M4 CloudKit BLOB sync** still needs two-real-device verification (ADR-0009 §4).
- **Bounded-intelligence gates.** `docs/M6-EXECUTION.md`: wire `TravelProfile`; review
  chat's direct `create_idea` durable-write authority. Decision gates, not an
  implementation queue. House memory marks the M6 AI thread paused pending yes-chef while
  M5 dogfooding is the active thread.

## Superseded framing — provenance, see the ADRs (do not build from these)

Older long-form direction notes, kept only as pointers; the real record is the ADR:

- **AI pool-stocking / discovery pipeline** → ADR-0018 + `docs/M6-EXECUTION.md` (M6e).
  The `findPlaces`/`createIdea` App-Intent verb vocabulary is the later composable
  payoff, not a v1 slice. Adjacent long-term bets from the same 2026-06-22 chat (match
  *prediction*, semantic pool search, latent-trip clustering) ripen into their own
  entries when real.
- **In-app conversational assistant framing** → superseded by ADR-0014 (AI strategy),
  GalavantAI substrate, ADR-0016 (M6c capture), ADR-0017 (M6d chat panel).
- **Guide-link enrichment + in-app browser generalization** → automated rung shipped
  (ADR-0021); the reusable "load URL → rendered HTML → run an extractor" piece is largely
  covered by the persistent browser (ADR-0025) and the `WebExtractorKit` lift. Re-check
  those before treating as open.
- **Portfolio extraction seams (parser engine + image tools)** → `WebExtractorKit` lifted
  to `jon-platform/packages`; image processing isolated in `GalavantImaging`. Honor
  "isolate now, extract on the second real consumer" (ADR-0006) when touching these.
