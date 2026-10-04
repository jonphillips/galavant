# Open questions & candidates

The architect's and Jon's scratch pad: candidates, designed-but-unscheduled work, and parked decisions.
**The executor never reads this file** (jon-platform ADR-0005). Work becomes dispatchable only when a
plan PR moves it into a milestone or effort and sets `docs/NEXT_UP.md`. Seeded 2026-09-29 from the
retired `CURRENT_HANDOFF.md` and `ROADMAP.md`'s open items.

## Candidates

- **Full-screen day map from Today.** The Today map card (effort `today-day-map`) is deliberately
  non-interactive, so it doesn't fight the scroll view, and has no follow-mode control. If Jon wants to
  pan or zoom on the ground, a tap on the card opening a full-screen interactive day map (with
  `MapUserLocationButton`) is the natural next step. Wait for dogfood evidence before adding it.

### Trip seed handoff (ADR-0048, proposed 2026-10-04)

Bridges an open-ended Chat "bearings" conversation into a Galavant trip: a `seedTrip` verb, a
narrative + JSON return, `.declined` status, a `TripDocument` founding document, and a bulk review that
matches saved ideas before searching the map. Awaiting Jon's ratification. **Slice 0 is Jon's:**
hand-run the Appendix A clause in the Denmark conversation and compare against
`docs/fixtures/seed-denmark.txt` before Slice 2 is dispatched. Slice 1 (`.declined` + `TripDocument`)
is dispatchable on ratification and doesn't depend on Slice 0. ADR OQ1–OQ4 stay in the ADR.

### M9 cockpit polish (post-ship follow-ups)

M9 (recommendation handoff + evaluation cockpit) and the LLMHandoffKit lift shipped and
are dogfooded (`docs/DONE-LOG.md`). Slices 3 (dossier flyover, #100) and 4 (iPhone parity,
#101) shipped 2026-08-23. Remaining, non-blocking:

- **Choose One day-anchoring.** Marking 2+ candidates + Choose One builds an
  alternatives ring (ADR-0035), but the ring is dayless/`.considering`, so it never
  appears on the itinerary. Commit the ring **to a day** at creation (born scheduled).
- **yes-chef adoption of LLMHandoffKit** (ADR-0036 consumer #1). yes-chef has an
  equivalent handoff spine; converging it onto the shared jon-platform package is its own
  repo/PR (like the WebExtractorKit lift's still-open yes-chef rewire).

### Pending Xcode 27.0 re-verification — cross-day drag + sectioned inline reorder

Within-day drag-to-reorder ships (#72; `dayRank` for Anytime stops per ADR-0033). Two
related next steps depend on the DnD subsystem; their beta limitations need
re-verification against the release build:

- **Drag stops across day sections** and **out of the "To Be Scheduled" bucket onto a
  day** — same gesture: drop target → day number → `TripIdea.schedule(.onDay(n))` /
  `scheduleUnplaced`. Needs cross-section drag (single-collection `reorderable()` can't).
- **Sectioned inline reorder** — render day-anchored rows (hotel/calendar/home-base/now)
  inline at their time position and drag events between days, via the
  `reorderContainer(for:in:)` overload.

Both need the sectioned reorder overload, **recorded dead on beta 5; re-verify on Xcode 27.0 release** (#73). Full spec
with the two paid-for gotchas (no custom `dragContainer`, no long-press `.contextMenu` in
a reorderable row) and a spike-first plan:
`docs/efforts/sectioned-reorder-inline-boundaries.md`. Durable fallback if reorder stays
broken: render the itinerary as `ScrollView`/`LazyVStack` instead of `List`. See
`docs/KNOWN-ISSUES.md`; menus cover the function meanwhile.

## Designed / deferred (product)

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

- **Today map reframe after a sync.** `TodayDayMapCard` frames only on appear, on a day change,
  and at the first device fix. If a sync adds or locates a stop while Today is open, the camera keeps
  the old box. Wait for dogfood evidence; the fix is to key the reframe on the day's points rather
  than `day` alone. (From the #145 review.)
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

## Superseded framing — provenance, see the ADRs (do not build from these)

Older long-form direction notes, kept only as pointers; the real record is the ADR:

- **AI pool-stocking / discovery pipeline** → ADR-0018 + `docs/milestones/M6-EXECUTION.md` (M6e).
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
