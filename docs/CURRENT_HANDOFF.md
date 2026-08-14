# Current Handoff — what's next

Granular enhancement notes that are still **open**: on deck, in progress, blocked,
or designed-but-not-yet-built. Not milestone-scoped (see `ROADMAP.md` for those).
Companion to `docs/DONE_LOG.md` (what's already shipped) — this file used to be
one long `docs/BACKLOG.md`; split 2026-07-11 to keep token cost down when an agent
reads it for context.

Ordered roughly **active/blocked first, someday/design-only last** — not a strict
priority queue, just enough to skim top-to-bottom sensibly. Each entry carries
enough context to act on cold.

## In progress — M9 ADR-0037 evaluation-workspace layout revision (browser + iPhone)

The evaluation-workspace core shipped and is settled (ADR-0037 Phases 1–2: candidate rail +
always-one-selected loop, three-layer map, the **Use This Place** resolve, and Save/Add/dismiss
— see `DONE_LOG.md`). What remains open is **layout**: Phase 3 (the state-driven persistent
research browser + field-bar official-URL write-back, PR #31) and Phase 4 (the map-first iPhone
inbox sheet + full-screen research browser, PR #32) are built and merged, but the **layout is
about to be reworked significantly** — so they stay current, not done. Treat the shipped
arrangement as a working baseline, not a finished design; the pure model/traversal core
underneath is stable and should not need to change (ADR-0037 D7 — layout only). Rationale:
ADR-0037; milestone arc: ROADMAP M9.

## Next — M9 the lift (ADR-0036 S3, designed not built)

Extract the handoff spine (session record + token + contract marker + return-split, genericized
over source/task + scopeKey) to `jon-platform/packages/LLMHandoffKit`; rewire yes-chef; Galavant
consumes as consumer #2. Copy-then-lift sequencing already resolved (ADR-0036 OQ2) — a later
behavior-neutral refactor, not a gate on the workspace. Rationale: ADR-0036.

## In progress — M7 Slice 1 calendar reconciliation (ADR-0034)

The calendar direction has been reversed (ADR-0034, 2026-08-10): the couple's shared
Apple Calendar is authoritative for real commitments, and Galavant **ingests and
reconciles** in-scope events for a dated trip instead of projecting the one-way
`Galavant: <trip>` mirror. The shipped export is demoted, not deleted (future "Add to
Shared Calendar"). Slice 0 cleared its EventKit observation gate on 2026-08-10.

Slice 1 (`codex/m7-s1-calendar-ingest`) now reads the dated trip's full civil-day
window, resolves every event through the existing `PlaceMatcher`, and renders a
read-only, in-memory reconciliation view. Its conservative ladder auto-identifies
only a unique same-day Apple Maps identity; a unique normalized name is merely a
proposal; ties and unknowns stay visible without writing a link, ledger, or Calendar
record. The remaining gate is **real shared-calendar dogfooding**: exercise obvious
matches, same-name ties, unmatched obligations, denied/revoked access, and refresh on
foreground before promoting the slice to done. Full sequence: ROADMAP M7; rationale:
ADR-0034.

## In progress — M7 Slice 3 shared ledger + cross-device dedup (ADR-0034)

Slice 3 (`codex/m7-s3-shared-ledger`) promotes only the reviewable outcome into
the trip's shared CloudKit graph. The EventKit binding remains device-local, while
each shared ledger row is keyed by a deterministic hash of the Calendar item's
server identity/revision and the applied semantic change. Raw EventKit identifiers
and device observation times never sync; two phones observing the same event change
therefore write the same record. Existing local Slice 2 history is deliberately not
guessed into shared state because it lacks that cross-device source fingerprint.

## In progress — M7 Slice 4 temporal subsystem (ADR-0034)

Slice 4 (`codex/m7-s4-temporal-subsystem`) captures EventKit time as one of three
semantic values: absolute instants with their display zone, floating civil date-time,
or all-day civil ranges. Availability remains distinct from occupancy, so all-day,
free, and tentative events do not manufacture hard-busy intervals. Recurrence binds
one occurrence by its original scheduled anchor (including a detached/moved instance),
never the whole series. Absolute instants project onto trip days in the trip's
**destination (region) zone** — derived by reverse-geocoding the trip's planning
region — which is the single civil-day frame for every event shape; a matched
venue's own MapKit zone is only a fallback for a region-less trip, never an
override (a wrong worldwide name-match must not push a just-after-midnight event
onto the prior day). When neither a region nor a place zone resolves, the event
stays a visible "Time Zone Needs Review" reconciliation item rather than falling
back to the event or device zone, and is never silently dropped. Local
recurring bindings retain source + occurrence identity and heal a replacement EventKit
identifier before applying a detached occurrence's move. The complete semantic
commitment round-trips through the shared ledger while legacy Slice 2 local history
and Slice 3 ledger rows still decode. The remaining gate is the slice PR plus real
Calendar dogfooding across home/travel zones and a modified recurring occurrence.

## In progress — M7 Slice 5 Calendar-originated constraints (ADR-0034)

Slice 5 (`codex/m7-s5-calendar-constraints`) promotes an eligible unmatched shared-
Calendar event into a synced `CalendarTripConstraint`: a deterministic, cross-device
identity; full temporal/availability snapshot; trip-day projection; and a device-local
EventKit binding. Constraints render in the itinerary timeline without becoming pool
ideas or Galavant-authored stops. A healthy full-access read may remove one only after
both its local EventKit ID and server identity corroborate absence; permission loss,
calendar-selection loss, moved events, replacement local IDs, and an individually
missing recurrence while its series remains visible infer no deletion. Existing
Galavant-originated linked stops never enter this deletion path.

Slice 5 merged via PR #22. An architect review + two dogfood passes then surfaced two
reap gaps where a constraint orphaned in the itinerary and never self-healed, both
fixed in **PR #23** (branch `fix/m7-s5-constraint-moved-outside-and-rekey`): (1)
**moved-outside** — a constraint whose event moves past the trip window now drops its
shared row while keeping the device-local binding (recreates on return), instead of
lingering on its old day; (2) **re-keyed recurrence** — converting a recurring series
between all-day and timed re-keyed the occurrence anchor and left permanent duplicates,
now superseded by a `(series externalIdentifier + trip day)` slot key (verified stable
against the EventKit headers). Pure-core tests cover both; suite green 16/16.

Remaining gate: real shared-Calendar (iCloud/CalDAV, **not** a local calendar — only
those carry the stable `externalIdentifier` a constraint needs) dogfooding of create,
edit, move-within, move-outside, delete, two-device convergence, and the all-day→timed
recurrence conversion, for a non-place obligation.

Deferred product notes from the review (non-blocking, revisit after dogfooding):
- **No dismiss/convert affordance.** Every eligible in-scope event becomes an itinerary
  row with no way to hide it or promote it to a real stop. Justified by ADR-0034 §2
  ("reckon with every event"), but a recurring daily commitment during a trip can
  clutter; watch during dogfooding.
- **`free`/`tentative` events still render as rows** (with a detail line). Correct per
  §2, but consider whether a `free` obligation deserves an itinerary row at all.
- **24-hour clock.** `constraintTime` renders `HH:MM`; confirm it matches the rest of
  the itinerary's clock style.

## Dogfood gate — M7 Slice 2 auto-apply + local history (ADR-0034)

Slice 2 (`codex/m7-s2-auto-apply`) establishes only a device-local EventKit binding:
one unique, same-day Apple Maps identity with a stable local EventKit identifier may
link to one itinerary stop, and later observations of that same local event
automatically refresh the stop's pinned date and clock time. Its `.linked` authority
disables Galavant-side time and booking edits on that device; `.manual` continues to
cover typed pins. Every link/update is retained as device-local review history. A
linked event that is explicitly found outside the trip window is recorded as **moved
outside this trip** without rewriting or deleting the itinerary stop; a missing lookup
remains unknown, never deletion. A name-only proposal, duplicate automatic candidate,
display-only fallback identity, or malformed temporal range also never writes. Slice 4
lifts Slice 2's former all-day, recurrence, and cross-day restrictions. The synced
`TripIdea` cache is deliberately not a synced EventKit binding — the shared ledger
does not make an EventKit binding global. Remaining gate: dogfood a real shared
reservation, then inspect a later time/day move and a moved-outside-trip notice in
local history.

The read-only proposal tier also flags a nearby, differently resolved Maps place when
both sides have coordinates within 100m and share a meaningful normalized name token.
It is explicitly `.proposed(.nameAndProximity)`, never an automatic link or write.

## Parallel / independent — the M5 real-device gate (calendar removed)

Still worth running, now decoupled from calendar: a TestFlight build on both phones to
verify travel-party share acceptance, two-way CloudKit changes, image/BLOB round
trips, and pinned-reservation behavior. Checklist: `docs/M5-EXECUTION.md`. The old
"manual Calendar export on both devices" check was dropped per ADR-0034.

The bounded intelligence follow-ups in `docs/M6-EXECUTION.md` (wire `TravelProfile`;
review chat's direct `create_idea` durable write) remain decision gates, not an
implementation queue.

## Trip header image — "romance" (from Jon, 2026-06-14)

**Being implemented under [ADR-0032](decisions/0032-trip-header-image.md) on branch
`feat/trip-header-image`** (verified the V1/V2 Unsplash key still authenticates,
2026-07-04). Decisions there: store a *hotlinked reference* (four flat columns on
`Trip`), not bytes — no new table, no FK, so it sidesteps ADR-0007 and needs no sync
registration; injectable `UnsplashClient` in `GalavantPlaces`; `registerDownload` +
attribution per ToS. Placement is the open review call — currently a hero band atop
the detail panel (the map-first canvas has no title area).

The trip screen looks stale; Jon wants a **selectable header image** so a trip
*feels* like its place ("feel like Copenhagen"). Worth the vertical space.
Precedent: V1/V2 GalavantLibrary `UnsplashSearch` (already a tested SPM module —
docs/MINING.md M5 row) let you pick from an image service. Plan: a per-trip
image (search Unsplash by destination/region name, or pick from Photos), shown
as a large header on the planning screen behind the title. Considerations:
needs an Unsplash API key (confirm the service/free tier still exists, else
swap source) + attribution; store the **choice** (URL/asset id + author) on
`Trip` and CloudKit-sync it; cache the bitmap locally (don't sync blobs). This
is the romance/polish pass — ROADMAP already lists "Unsplash header images" under
M5; this elevates it. A focused feature, not a quick tweak — do it as its own
slice.

## Multi-select tag assignment on Ideas (from Jon, 2026-06-13)

The data model already supports many tags per idea (IdeaTag join), but the form
adds them **one at a time** (type-and-add with autocomplete). Jon wants a
**multi-select tag picker** (confirmed 2026-06-13): a scrollable list of all
existing tags with checkmarks, toggling several on/off at once. **A dedicated
screen is acceptable** (push from the form's Tags section → tag-picker screen →
back). Keep the type-to-create-new-tag path available there too. The current
one-at-a-time add stays as the inline quick path; this is the "manage many"
surface. Likely reuses TagManagerView's list shell.

## Guide-link enrichment rung + generalized in-app browser (ADR-0016 follow-on, 2026-06-24)

**Automated rung DONE (2026-06-24, ADR-0021, branch `feat/guide-link-enrichment-rung`).**
The four pieces shipped, each tested:

1. **Link extraction** — `ParsedPage.links: [URL]` (absolute http(s), in document
   order, de-duped, fragment-stripped, self-link excluded); `PageParser` harvests
   anchors before the boilerplate strip; `ParseBuilder.addLink`.
2. **`GuideLinkRecognizer`** (pure, `GalavantCapture`) — host ∈ a known guide **and**
   a place-detail path shape: a known detail-path marker (Michelin `/restaurant//hotel/`
   + a slug after it) **or** generic depth ≥ `minDetailDepth` (3, derived from
   locale→region/category→place) with a hyphenated final slug that isn't a section
   keyword. Host list lifted into a shared `GuideHosts` table that `EvaluationRecognizers`
   now also consumes (one definition; the `name` doubles as the `IdeaEvaluation.sourceName`).
3. **Enrichment hop** — `PlaceEnricher.followingGuideLink` follows **one** link via the
   existing `pageFetcher`, parses it (host = guide → ★★★), and folds it in via the new
   pure `ParsedPage.fillingBlanks(from:)` (fill-blanks scalars, append-dedup collections,
   (source,kind,value)-dedup evaluations). The single write now also records the merged
   page's evaluations (`IdeaEvaluation.record`, `.official`) — **first time the second
   hop writes judgments**, not just facts/images.
4. **Crawl-sprawl guards** — at most one link; skipped when the idea already carries
   that guide's judgment; rides the `enrichedAt` once-gate; best-effort; no transitive
   crawl (links on the guide page aren't followed).

**Still NEXT — the in-app browser is the human fallback rung of this same effort — not a separate
track.** The automated hop above does a plain URLSession fetch (the enricher's
`pageFetcher`), which fails on exactly the pages a rendered DOM fixes (JS-heavy,
anti-bot, consent/paywall). A HITL `WKWebView` already ships, but hard-wired to
hours rung-3: `HoursBrowserView.swift` ("Find Hours", `onGrabHours`, stamps
`.unverified`) — it renders JS, holds a session, clears consent walls, scrapes
`document.documentElement.outerHTML`, runs the parser. The recurring theme across
all surfaces is "raw fetch < rendered DOM": the **share extension** gets the
rendered DOM free via Safari JS preprocessing; **hours rung-3** via that WKWebView;
the **app-side enricher** (where this lives) has no rendering — that's the gap.

Sequencing: ship the automated guide-link rung first (handles most static guide
pages, and surfaces which pages actually need rendering), **then** generalize
`HoursBrowserView` into a reusable "load URL → hand back rendered HTML → caller runs
any extractor" component, with hours as one consumer and the guide-link fallback as
the next. Refactor with a real driver, not a speculative general browser. (Bigger
someday vision — "browse to any place, tap capture" as a general entry point — is
out of scope here; keep it to the extraction-fallback role.)

**Note (added at the 2026-07-11 backlog split):** a generalized in-app browser has
since shipped as the **persistent browser** (ADR-0025, branch `feat/persistent-browser`)
for other reasons (field capture). Re-check before starting this: the reusable
"load URL → rendered HTML → run an extractor" piece this entry wants may already be
substantially covered by that work.

## Drag itinerary stops between days / out of the bucket (from Jon, 2026-06-13/14) — BLOCKED (Xcode 27 beta 1)

Attempted and **backed out** 2026-06-15 (M3d follow-up): **List drag-and-drop is
broken on Xcode 27 beta 1** — every drop times out (`Gesture: System gesture gate
timed out`), the lift works but the drop never lands. Tried three different `List`
drop surfaces, all failed on device: (1) `.dropDestination` on the **section
headers** (don't register as drop targets — a real `List` limitation, not just
beta); (2) the iOS 27 **reorder container** (`.reorderable(collectionID:)` +
`.reorderContainer(for:in:)`, the Apple-sanctioned path) — flaky on this beta,
matching the **Someday reorder** known-issue; (3) `.dropDestination` on the
**rows** + empty-day placeholder (the standard, usually-reliable surface) — also
times out. Three surfaces failing on one beta points at the beta's DnD subsystem,
not our code. Reverted to keep the tree clean; the `StopMenu`'s Move-to-Day /
To-Be-Scheduled fully covers the function meanwhile. See docs/KNOWN-ISSUES.md.

**Revisit on a later beta.** If row/reorder DnD still fails, the durable fix is to
render the full itinerary as a `ScrollView`/`LazyVStack` (no `UICollectionView`
interception) rather than `List` — a bigger change, deferred until it's worth it.
The model ops are trivial to re-add (`schedule.onDay(n)` / `scheduleUnplaced`).
Original note below.

M3c places/reorders stops via a "Move to Day"/"Set Day" menu + the Add-Stop
sheet. Jon wants stops **draggable across day sections** directly — *and* (added
2026-06-14) **dragging items out of the "To Be Scheduled" bucket onto a day**.
Both are the same gesture: drop target → day number → `TripIdea.schedule(_.onDay(n))`
(or `scheduleUnplaced` to drop back into the bucket). Needs cross-section drag
(the M3b `reorderable()`/`reorderContainer` is single-collection). ~~Within-day
reordering is moot (stops auto-sort by time)~~ — **no longer true as of ADR-0033**:
untimed "Anytime" stops now hold a manual intra-day `dayRank`, so within-day reorder
is a real gesture (see the ADR-0033 Slice 4 entry — shipped, `docs/DONE_LOG.md`).
Fast-follow; the menus cover the cross-day function until then.

## Grow the Itinerary stop detail into a richer screen — remaining scope (from Jon, 2026-06-14)

**Still deferred** (the reasons to break out of the panel into full-screen):
**MKDirections travel time** from the previous stop, **opening hours**, and
**booking** — revisit once that data exists on the model. See
`docs/DONE_LOG.md` for what already shipped (the in-panel drill-down + the first
content growth, 2026-06-15).

## Itinerary stop menu is overloaded — split display from actions (from Jon, 2026-08-13)

The itinerary stop row's time control (`StopMenu`, `Galavant/Trips/StopMenu.swift`)
is doing two jobs at once: its **label** displays the stop's time (a clock glyph,
`"Lunch"`, or a `HH:MM` range — `timeLabel`), while tapping it opens a menu that is
really the stop's *entire* context menu — Time of Day, Set Time, Move Earlier/Later,
Move to Day, To Be Scheduled, **Add Alternative**, Pin Reservation, Mark Skipped,
Remove / Move to Shortlist. So a glyph that reads as "when" secretly holds every
lifecycle action, none of it advertised (Jon, seeing it during M8 Slice 3: "that
clock menu is doing A LOT").

Two smells: (1) the trigger is mislabeled — a *value display* doubling as the
action trigger for everything; (2) the contents span two mental models jammed
together — **when** (time-of-day / set-time / move-day / reorder) vs
**what/lifecycle** (add-alternative / pin / skip / remove). Direction whenever this
is touched: let the time label just *be the time* (tap → set time), and move
lifecycle/day/alternatives to a proper `⋯` on the row or swipe actions. That also
un-buries **Add Alternative**, which is currently three levels deep behind a clock
even though it's the M8 feature. Not urgent; explicitly **not** folded into M8
Slice 3.

## Itinerary completion model: trip-level done→visited rollup (from Jon, 2026-06-13)

**Still deferred:** the inferred completion / **trip-level done→visited rollup**
(flip a past trip's non-skipped scheduled ideas' `visited`) — the
`TripIdea.markDone` op + test remain the mechanism; only the trip-level trigger is
unbuilt.

Background: Jon removed per-stop **Mark Done** from M3c — "no one wants to mark
Done on an itinerary; just assume they did it." Skipped stays (an explicit
negative signal). So completion should be **inferred**, not tapped: once a trip's
day/time has passed, its non-skipped stops are effectively done. Consequence for
the **done→visited** feedback loop (ADR-0004): it moves from a per-stop action to
a **trip-level rollup** — when a trip is past/marked complete, flip its scheduled
ideas' `visited`. The `TripIdea.markDone` op + test stay (the mechanism); only the
UI trigger changes. Design item; pairs with weather/"now" work on the trip canvas.
See `docs/DONE_LOG.md` for what already shipped (the "now" you-are-here marker,
2026-06-20).

## Codex alignment-review follow-ups (2026-06-16)

Deferred items from `docs/reviews/codex-alignment-review-2026-06-16.md`. The
review's two acted-on items landed already: the filtered swipe-delete bug fix
(`IdeasListModel.deleteIdeas` now takes the displayed array) and the CLAUDE.md
iOS-26→27 correction. The rest, in rough priority order:

- **Regression test for filtered swipe-delete.** The fix is structural (the view
  hands `deleteIdeas` the exact `filteredIdeas` it rendered), but there's no
  automated guard against a future re-wiring. Blocked on test infrastructure:
  the app target has **no unit-test bundle** (only `GalavantSchemaTests` in the
  package + `GalavantUITests`), and a destructive UI test can't be made
  deterministic because there's **no DB-reset launch arg** (the app-group DB
  persists across launches; `--reset-identity` only clears `currentPlannerID`).
  A real regression test wants one of: an app unit-test target exercising
  `IdeasListModel`, or a `--reset-database` arg + a seeded UI test that filters
  to one region (e.g. New York) and verifies the swiped row — not the
  global-alphabetical-first idea — is the one deleted.

- **ADR-0008 sync-dedup hardening.** — DONE (2026-08-12, PR #20). Shipped the
  `LogicalUniqueness.convergingByKey` pure helper (lowest-UUID survivor), IdeaInterest
  non-mutating dedup-on-read + owning-write loser cleanup, IdeaTag/TripRegion cleanup,
  and `TravelParty.ensureDefault` prefer-populated + repoint-before-delete (all 7 child
  tables) + single-party fast path; 9 seeded-duplicate tests. See `docs/DONE_LOG.md`.
  **Two follow-ups still open:** (1) real two-device dogfooding of the TravelParty merge
  — it deletes party rows and repoints children, and that convergence only manifests on a
  genuine offline race; (2) `Planner.create` **planner-level** dedup — merging two
  *populated* parties currently repoints blindly and can leave duplicate planners/tags
  (extreme edge; merge-with-dup beats data loss). Adjacent to "Planner identity feels
  fly-by-night."

- **Schedule doc-drift sweep.** — DONE (2026-06-23). Updated `docs/PRODUCT.md`,
  `docs/STYLE.md`, and `docs/decisions/0004-pull-based-trip-membership.md` to the
  V3 vocabulary (`unscheduled / day / daypart(DayPart) / timed`, calendar dates
  derived from the trip's start, `.exact` dropped). `docs/ROADMAP.md` was already
  corrected (the M3c entry notes "drops V2's `.exact`"); the review's other
  `.exact` mentions (`trip-time-model.md`, `recovered-requirements.md`) are
  correct history and left as-is.

- **UUID dependency-control for *new* schema ops.** Operations call `UUID()`
  directly (`TripOperations`, `PoolOperations`, `Tag`, `TripRegion`, `IdeaTag`).
  Don't churn working code, but new vertical slices should accept IDs as args
  (model supplies a dependency-controlled `@Dependency(\.uuid)`) rather than
  spreading direct `UUID()`.

- **Standardize derived bindings.** — DONE (2026-06-23). `TripPlanningView`'s two
  sites were already gone. The `TripPlanningSheets` "Show visited" toggle now uses
  `@Bindable var model` + `$model.includeVisited` (the codebase's established
  idiom). The `RegionManagerView`/`TagManagerView` rename alerts drive off an
  optional *struct* payload → bool — which `@Bindable` and the current
  SwiftUINavigation case-path bindings (enum-only) don't cover — so they now use a
  small reusable `Binding.isPresent()` helper
  (`Galavant/Navigation/Binding+Present.swift`), the local pattern to copy.

- **Swallow `CancellationError` on one-shot model reads.** — RESOLVED, no code
  change needed (verified 2026-06-23). The pinned `withErrorReporting`
  (xctest-dynamic-overlay) already catches `CancellationError` and ignores it in
  every overload (sync + async — `ErrorReporting.swift` `catch is CancellationError`).
  Both `IdeaFormModel` and `TripFormModel` wrap their `.task` reads in it, so a
  cancelled read is silently swallowed, never reported. The review's concern
  predates this library behavior (or assumed it reported all errors).

- **Document `-skipMacroValidation` for headless verification.** First Xcode CLI
  build stops on macro re-approval; `xcodebuild … -skipMacroValidation build`
  succeeds. Worth a line in CLAUDE.md's toolchain/verification notes (does not
  replace human Xcode macro approval).

- **jon-platform shared-doc refinements (not galavant-local).** The review's last
  section proposes folding five rules into `~/code/jon-platform` (displayed-
  collection delete/reorder rule; split-view nested-NavigationStack clarification;
  UUID-generation nuance; one-shot-read cancellation note; macro-validation CLI
  note). These belong in the house knowledge base, not here — apply there.

## Planner identity feels fly-by-night (from Jon, 2026-06-12)

The name-only "Who are you?" prompt feels flimsy; Jon wants a stronger key
(email on file, collision-resistant). Resolution direction recorded in
**ADR-0008 → "Future: back planner identity with the CloudKit participant"**:
derive identity from the accepting Apple ID (unique key + name/email when
consented), `displayName` as editable override. Blocked on the M5 real-device
share-accept flow. Cheap interim option: optional typed `email`/subtitle on
`Planner` for picker disambiguation.

## Consolidate management UIs into a settings/"You" area (from Jon, 2026-06-12)

Tag and Region management currently hang off the filter menu (Manage Tags… /
Manage Regions…). That's a temporary home — these (plus planner identity/
switching and sync health) should migrate into a dedicated settings or "You"
nav section, not be buried in the filter. Punted for now; tracked here. Likely
lands when the third nav section ("You"/Account) is built (M5-ish).

## Accommodations (from Jon, 2026-06-13) — DESIGNED

Design settled in **ADR-0011** (2026-06-20): a sibling **`TripStay`** record (one
FK → `Trip`, loose optional `ideaID`, freeform-capable, `checkInDay`/`checkOutDay`
+ optional `"HH:mm"` times), *not* a `Schedule` case — the span inverts ADR-0010's
one-record logic. Itinerary = a home-base chip on every covered day header +
check-in/check-out timeline rows (new `ItineraryItem.checkIn`/`.checkOut`); canvas
= a distinct off-sequence base pin, unnumbered, off the day polyline. Stays are
born on the trip (not pulled); overlap is allowed-but-flagged. Deferred seams:
booking metadata/`pinnedDate` (trip-time-model §4), per-day-region *driving*
(display-only for now), a "Stays" summary band, hotel-anchored routing.
Implementation not yet started. See ADR-0011 for the full rationale (incl. why a
sibling record, not a `TripIdea` extension).

**Note (added at the 2026-07-11 backlog split):** house memory records "all 3
slices shipped" for accommodations since this entry was written — re-verify
current status against `docs/ROADMAP.md` / recent commits before treating this as
still fully open; it may already be DONE and this entry stale.

## Historical M6 discovery notes — superseded by the rebaseline

This is retained for provenance, not as a build brief. `PlaceDiscoveryClient` exists
only as grounded-request infrastructure; the advertised resolve/dedup/persist/review
pipeline has not shipped. Do not resume this plan without first using
`docs/M6-EXECUTION.md` to decide whether frontier discovery is worth pursuing at all.

> **Designed as ADR-0018 + M6e (2026-06-23).** The discovery-pipeline first slice
> below is now settled in `docs/decisions/0018-ai-pool-stocking-discovery.md` with an
> execution brief in `docs/M6-EXECUTION.md` (M6e): one grounded `complete()` web-search
> call → JSON candidates → reuse `PlaceMatcher`/`DiscoveryDedup` → candidate Ideas;
> frontier-only/BYO-key; slice-0 spike gates discovery quality. The `findPlaces`
> App-Intent verb vocabulary (the rest of this entry) remains the later composable
> payoff, not the v1 slice.

**Note (added at the 2026-07-11 backlog split):** house memory marks the M6 AI
thread **paused pending yes-chef** while M5 dogfooding is the active thread — treat
this as lower priority than the M5-band entries above until that pause lifts.

The concrete, bounded first slice of the "AI assistant / chat" theme above: not
open chat, but a small **action layer**. The organizing principle (from the
2026-06-22 design chat) — **AI stocks and understands the pool; it never decides
the trip.** PRODUCT.md already says "a trip never automatically contains anything";
that explicit-**pull** boundary is exactly where AI stops. AI may fill the junk
drawer aggressively and help with the *mechanical* parts of scheduling, but the
taste calls (what's worth pulling, what makes the trip) stay Jon's. Jon's own best
example: *"find me all the 2- and 3-star Michelin restaurants in the Loire and
create ideas for them"* — research that **stocks** the pool, where pulling is still
manual, so it feels safe.

**Architectural fit (no new UI concept):** ADR-0013 already distinguishes
**candidate vs. pulled** pins. AI-generated ideas land as **candidates** — Jon
dispositions them on the map exactly as he does today. AI is just a third,
tireless source feeding the pool alongside share-extension capture and manual
entry.

**The discovery pipeline (generalizes the Michelin case).** This is *discovery*
(query → a set of candidate places), distinct from today's *enrichment* (fill in
an already-known place). Steps:
- Query + region → a candidate set ("2–3⭐ Michelin in the Loire"; "natural wine
  bars in Lisbon"; "playgrounds near our Rome stops").
- Each candidate becomes a **candidate `Idea`**, auto-bucketed into the right
  `MapRegion`, auto-`IdeaKind`/auto-tagged, enriched on-device via the existing
  `PlaceIntelligence` (`FoundationModels`) + `GalavantPlaces` search stack.
- **Dedup against the pool is the non-obvious essential** — don't re-add the
  places already saved; flag near-matches. Reuse the existing place-matching in
  `GalavantPlaces` (`PlaceMatcher`).

**App Intents — two distinct payoffs (don't dismiss because we're not on the App
Store):**
- *Personal friction reduction.* "Hey Siri, add this to our France ideas";
  Spotlight-search the pool from the home screen; a geofence Shortcut that opens a
  region's ideas on arrival; a glanceable "today's stops" widget.
- *The substrate (the real reason).* Define a small, safe **verb vocabulary** as
  App Intents over the tested schema core — `findPlaces`, `createIdea`,
  `scheduleStop`, `rateIdea` — and expose `Idea`/`Trip`/`Region` as `AppEntity`s.
  Then the Michelin sentence isn't a bespoke feature; it's a model decomposing the
  request into `findPlaces` ∘ `createIdea`. Build the action layer once; natural
  language orchestrates it. This is what makes the whole pool-stocking theme
  *composable* rather than one-off.

**Open design questions (need a real pass):**
- **Discovery quality is the main risk.** Does "all Michelin in the Loire"
  actually return the right set? Worth a **throwaway spike** before committing —
  if the candidate set is wrong/incomplete, the feature is noise. On-device
  `FoundationModels` is great at *structuring* a known place but is not a
  web-search index; discovery likely needs web fetch (in-app, no server per
  ADR-0001) and/or the Claude API — that's the where-it-runs/cost call the AI-chat
  entry already flags.
- **Live data** (real-time hours, availability, reservations) bumps the no-server
  constraint — feasible via on-device web fetch in enrichment, but flakier; keep it
  out of the first slice.
- **Two-person privacy posture** — same as the AI-chat entry.

**Suggested first slice:** the discovery → candidate-ideas pipeline behind a
`findPlaces` App Intent + a simple in-app entry (region-scoped themed search,
results reviewed as candidate pins on the pool map). Spike discovery quality
*first*; only then wire `createIdea` and the dedup pass.

**Adjacent bets surfaced in the same chat** (separate entries when they ripen, not
this slice): **match *prediction*** — extend the his/hers `Interest.standing`
projection from a lagging tally to a *predicted* match for unrated ideas (the most
differentiated long-term bet, unique to a two-person app); **semantic pool search**
("that cozy waterfront place we saved") via on-device embeddings; **latent-trip
clustering** (surface a someday-Jutland from 14 clustered ideas).

## Historical chat framing — superseded by the rebaseline

Embedded chat is now a real Ideas/Trip surface. Its remaining question is product
role and write authority, not whether to create a chat panel; see
`docs/M6-EXECUTION.md` before taking any follow-up.

A larger future theme, not yet milestone-scoped: an in-app conversational
assistant (Claude API — see CLAUDE.md model guidance) layered over the pool +
trips. Plausible jobs, roughly in value order: **capture/enrichment** ("add the
restaurant from this link", parse a pasted blog list into ideas — overlaps the
M4 scraping pipeline), **planning help** ("draft a 3-day Copenhagen itinerary
from my shortlist", "what's near Tivoli I've saved?"), and **Q&A over the pool**
("which Denmark food ideas haven't we visited?"). Wants a real design pass:
where it runs, what context/tools it gets (read the SQLite pool? call the
schedule ops?), cost, and the two-person-household privacy posture. Park here as
a direction; revisit after the core loop (M3/M4) is solid.

**Note (added at the 2026-07-11 backlog split):** house memory shows this theme
has since progressed substantially (ADR-0014 AI strategy, GalavantAI substrate,
M6c source-aware capture, M6d context-aware chat panel). Treat this entry as the
original framing/direction, largely superseded by those ADRs — check
`docs/decisions/` and `docs/M6-EXECUTION.md` before acting on it directly.

## Portfolio extraction seams: parser engine + image processing (from Jon, 2026-06-14)

Two capabilities coming up have a life beyond Galavant (Jon's wider app
portfolio, e.g. a future recipe manager): **web capture/parsing** (M4) and
**image storage tools** (M2 images). Decision: **isolate now, extract later** —
do *not* stand up a shared package against a single consumer (premature
extraction calcifies the wrong API). The expensive mistake is *entanglement*,
not late extraction; so build both as cleanly-isolated targets in the local SPM
package with strict boundaries, and lift to a neutrally-named shared package only
when a **second real app** needs them and both consumers' requirements are
visible (the "reason" CLAUDE.md requires for a new package).

Boundary discipline to enforce while building:

- **Parser engine = `HTML/text → generic structured struct`.** The portable unit
  is the *pure transform* (schema.org/JSON-LD/OpenGraph → normalized result), not
  "in-app browser." The browser is just one *source* of HTML (share extension and
  server fetch are others). Engine must never import SwiftUI/CloudKit and never
  see `Idea`/`Trip` — domain mapping (generic result → `Idea`) stays in the app.
  This also makes it unit-testable with zero browser/network. Aligns with the M4
  enrichment pipeline (docs/scraping-enrichment.md).
- **Image tools = split processing from storage.** Resize/compress/thumbnail are
  pure functions over `Data`/images — maximally portable, the clean extraction
  candidate. *Storage* ("dedicated table, CloudKit-synced, no S3" — ADR-0009)
  is stack-specific; it travels only if the other app also uses
  SQLiteData+CloudKit. Keep processing free of any persistence import.
- **Naming (ADR-0006):** a portfolio library needs a *neutral* name — no app
  domain in it. V2's `GalavantLibrary` was within-app and Galavant-named; that
  pattern is wrong for a cross-app package. Decide the name when the second
  consumer is real, not now.

No code action yet — this is intent to honor when M2 images and M4 capture get
built, so the eventual extraction is a rename-and-move rather than surgery.

**Note (added at the 2026-07-11 backlog split):** house memory records that
`WebExtractorKit` has since been lifted to `jon-platform/packages` (the in-app
browser cross-app reuse effort) — the parser-engine half of this intent may
already be substantially realized. Re-check before treating this as still fully
open.
