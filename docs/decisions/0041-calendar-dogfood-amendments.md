# ADR-0041: Dogfooding amendments to calendar reconciliation — human dismissal, manual match repair, and a time-zone display/assignment split with per-day zones

*Status: **accepted** — 2026-08-17. Three amendments to ADR-0034 (calendar
reconciliation authority), each forced by dogfooding the shared-calendar ingest on a
real trip (Bavaria/Dolomites, Sept 2026). It **amends** ADR-0034 §2 (adds a
human-decided dismissal path it deliberately omitted), **extends** §3–§4 (adds the
missing human confirm/correct affordance to the match ladder, plus two matcher
loosenings), and **amends** §10 (splits time-zone **display** from time-zone
**assignment** and makes zone a first-class per-day property, decoupled from the
romance region concept). Preserves ADR-0001 (no server), ADR-0003 (all new state is
domain state riding SQLite→CloudKit on the trip share), ADR-0004 (model/engine
proposes, human decides), ADR-0006 (flat columns, no version suffixes), and ADR-0034's
correctness invariants. Does not touch the authority boundary itself: Calendar remains
authoritative for linked commitments; Galavant remains authoritative for the plan.*

## Context

ADR-0034 shipped the ingest-and-reconcile direction: Galavant reads one user-selected
shared calendar in a dated trip's scope and reconciles each in-scope event against the
itinerary. Dogfooding it on a live trip surfaced three gaps between the ADR's stated
premises and how the shared calendar is actually used by two people.

1. **The shared calendar carries non-trip noise.** ADR-0034 §2 asserted that *every*
   in-scope event must be reckoned with — matched or turned into a
   `CalendarTripConstraint` — and explicitly refused an "ignore because it doesn't look
   like travel" path. That was correct against its premise that the shared calendar is
   trip-committed. In practice the couple has not fully moved onto Galavant, so the
   shared calendar still holds Wendy's personal notes and reminders that happen to fall
   inside the trip's civil days. §2 gives the planner no way to say "this one is not part
   of the trip," so the itinerary accretes noise it cannot shed.

2. **A conservative match ladder with no human backstop.** The reconciliation ladder
   (`CalendarReconciliation.result(for:plan:projection:)`) auto-links **only** on Apple
   Maps place identity (`mapItemIdentifier`). Exact-name and name+proximity produce
   `.proposed`; more than one same-day namesake produces `.ambiguous`. But the read-only
   view (`CalendarReconciliationRows.swift`) renders every non-automatic result as inert
   text — there is **no** affordance to confirm a proposal, pick among ambiguous
   candidates, or undo a wrong automatic link. The same restaurant on two days can
   therefore link on one and fall through on the other with nothing the planner can do.
   Observed concretely: "Ikigai" auto-linked on Day 9 (the Calendar event resolved to the
   same Maps place as the scheduled stop) but not Day 10, where the event resolved to a
   richer Maps name. The exact-name rung compares `matchedPlace?.name ?? event.title` — it
   prefers the Maps-resolved name and never falls back to the raw title — so "IKIGAI"
   missed the stop "Ikigai" and dropped to `.unmatched`, becoming a standalone constraint
   row beside the very stop it names.

3. **Time zone is welded to region, computed once for the whole trip, and overrides the
   event's own zone.** `regionTimeZone(for:)` takes the bounding-box centroid of **all**
   the trip's regions, resolves one `TimeZone`, and applies it uniformly to every day and
   event. Per-day region (`TripDayRegion`) is never consulted for zone. Worse,
   `CalendarTripConstraint.itineraryTimes` **discards** an absolute event's own carried
   zone and re-renders its clock in that single trip zone. So an RDU→Munich flight, whose
   Calendar event knows it departs in Eastern time, displays in Munich local time on the
   first day. The planner's instinct — "let me set the correct zone on Day 1" — has no
   lever: setting a *region* would not change the zone (per-day region is ignored for
   zone), and even if it did, adding a home-airport region to a Bavaria trip would drag
   the single centroid into the mid-Atlantic and misrender the destination days. This is
   exactly the failure ADR-0034 §10 warned about ("A home 10:00 America/New_York call
   constrains an Italy day at its real absolute instant while still showing as 10:00
   Eastern") — the invariant was stated but the display path does the opposite.

None of these are authority-boundary questions; ADR-0034's core split (Calendar owns
linked commitments, Galavant owns the plan) is unchanged. They are three concrete
corrections to how the boundary is *operated*.

## Decision

### 1. A planner may permanently, reversibly dismiss an in-scope event (amends §2)

§2 rejected **automatic** classification — the app deciding an event "doesn't look like
travel." That rejection stands. It did **not** contemplate a **human** deciding a
specific event is not part of the trip, which is an ordinary ADR-0004 taste call, no
different in kind from a human resolving an ambiguous match. Add that path.

A dismissal is durable, travel-party-shared, and reversible. Dismissing an event removes
it from matching and from constraint creation; it produces no itinerary row and no match
proposal. Un-dismissing returns it to normal reconciliation on the next read. Dismissal
is **trip-scoped and per-event**: it is keyed to the event's shared source identity
within one trip and rides that trip's CloudKit share, exactly like a
`CalendarTripConstraint`. A recurring personal note that recurs on a future trip is
dismissed again there — cross-trip "always ignore this series" is deliberately **out of
scope** for this ADR (it has no home on a single trip's share and is a heavier identity
problem; revisit only if the per-trip cost proves annoying in practice).

Dismissal obeys ADR-0034 §10's safety invariants: loss of visibility never creates or
destroys a dismissal, and a reappearing dismissed event stays dismissed via its identity
hash. An event confirmed deleted may have its dismissal reaped, but absence alone is not
confirmation — the same corroboration the deletion path already uses applies.

### 2. The match ladder gains a human backstop, and two loosenings reduce how often it is needed (extends §3–§4)

ADR-0034 §3 said "very strong matches link automatically; ambiguous ones become
reconciliation decisions," and §4 held the ADR-0004 line — the engine proposes, the
human decides. The *decision* affordance was never built. Build it, and make the ladder
propose better:

- **Confirm and correct.** A `.proposed` result gains a **Link** action that establishes
  the same durable link an automatic match would (the stop becomes `.linked`, renders its
  Calendar-derived pin, and follows Calendar authority thereafter). An `.ambiguous` result
  gains a **Link** action that first lets the planner pick which same-day stop. Any linked
  result — automatic or manual — gains an **Unlink** action that removes the binding, and
  the event reverts to normal reconciliation (it may then become a constraint). Manual
  linking is gated by the same shared-identity eligibility (`isEligibleForShared
  Reconciliation`, `hasStableLocalIdentity`) that gates automatic linking; an ineligible
  event is shown but not linkable, with the reason stated.

- **Exact-name considers the raw title, not only the Maps-resolved name.** The exact-name
  rung matches a stop when **either** the normalized Maps-resolved place name **or** the
  normalized raw event title equals the stop's normalized title. A Maps result that is
  richer than the planner's own stop name must not defeat an otherwise-obvious match.

- **A single unambiguous exact-name match auto-links.** When exactly one same-day stop
  matches by exact name and nothing else competes (no map-identity candidate, no second
  exact-name stop), the result is promoted to **automatic**. This is safe — one name, one
  day, one stop — and removes the most common reason a human would have had to link by
  hand. More than one namesake remains `.ambiguous` (a human decision), never a silent
  guess.

This keeps ADR-0004 intact: the loosenings only auto-apply where the evidence is
unambiguous; every genuinely ambiguous case still asks, and now the asking is actionable.

### 3. Time-zone display is split from time-zone assignment; zone becomes a first-class per-day property decoupled from region (amends §10)

§10 already names the correct model ("A home 10:00 Eastern call constrains an Italy day at
its real absolute instant while still showing as 10:00 Eastern") but the implementation
collapsed both roles onto one trip-wide, region-derived zone. Separate the two roles and
give the assignment role a proper per-day source.

- **Display zone.** A zoned (`.absolute`) event is displayed in its **own carried zone**,
  with a short zone tag (e.g. "6:00 PM EDT") so a genuinely two-zone travel day is not
  misread as a same-zone contradiction. This is the honest representation of what the
  traveler booked, and it fixes the RDU flight with no region or setting required. The
  reconciliation sheet already renders absolute events this way
  (`temporalDescription`); the itinerary row is brought into line. Floating events keep
  their civil clock; all-day is unchanged.

- **Assignment zone.** Deciding **which civil day** an absolute instant lands on still
  requires an itinerary zone (§10). That zone becomes a first-class, optional **per-day**
  property (`timeZoneIdentifier` on the trip-day representation, ADR-0006 flat-column
  style), resolved: **explicit per-day override → the day's `TripRegion` zone →
  trip-centroid** (today's behavior) as the fallback. Zone authority is thereby
  **decoupled from the romance region concept**: region stays a map/photo/lens idea, and a
  home airport is never modeled as a "region" of the trip. The per-day override is the
  planner's real lever for a transfer day; it also interprets that day's floating events.

- **The assignment chicken-and-egg is resolved conservatively.** Assigning an absolute
  event to a day needs a zone before the day is known, so the initial day projection keeps
  using the trip-default/centroid zone (today's behavior); the per-day override refines
  **display** and **floating-event interpretation** on the resolved day. Assignment is not
  made self-referential. This is deliberately the smaller correctness claim — the flights
  the dogfood surfaced are display problems, and multi-zone day-assignment edge cases can
  harden later without reopening this ADR.

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **Keep §2's no-ignore rule; hide noise heuristically** | Rejected. Heuristic "looks like travel" is exactly what §2 rightly refused. The real need is a human decision, which §2 never contemplated. |
| **Global / cross-trip ignore** | Deferred, not chosen. No home on a single trip's CloudKit share; a heavier cross-trip identity problem. Per-trip dismissal is the cheap, safe first cut. |
| **Leave the match ladder conservative; rely on manual link only** | Rejected as the whole answer. Manual link is the necessary backstop, but without the two loosenings the planner hand-links obvious same-name matches constantly. |
| **Make the matcher aggressive (auto-link any name/proximity)** | Rejected. Would manufacture wrong links (the `bar`/`barcelona` class of error §3's token rule guards against). Only the single-unambiguous-exact-name case is promoted. |
| **Display every event in the trip zone (status quo)** | Rejected. Directly violates §10's own worked example; renders booked flights in the wrong zone. |
| **Fix zone by adding a home-airport region** | Rejected. Overloads the romance-region concept with zone authority, and the single centroid corrupts destination days. |
| **Per-day zone that also drives assignment self-referentially** | Rejected for now. Assignment needs a zone before the day is known; forcing per-day assignment invites circular logic for marginal benefit. Display + floating interpretation is the high-value slice. |
| **Human dismissal + actionable ladder + display/assignment split with per-day zones (chosen)** | Solves the three concrete dogfood failures, each as domain state on the trip share, without reopening the authority boundary. |

## Relationship to prior decisions

- **ADR-0034 §2:** amended — a human dismissal path is added; the automatic-classification
  refusal stands.
- **ADR-0034 §3–§4:** extended — the "ambiguous becomes a decision" promise gets its
  affordance; two loosenings improve what the ladder proposes without breaking the
  auto-apply/ask line.
- **ADR-0034 §10:** amended — the display/assignment split it implied is made real; zone
  becomes per-day and region-independent. The safety invariants (loss of visibility is not
  deletion; moved-outside is not deletion; cross-device dedup) apply unchanged to the new
  dismissal state.
- **ADR-0004:** preserved and reinforced — dismissal and manual link are human decisions;
  the loosenings auto-apply only where unambiguous.
- **ADR-0003 / ADR-0001:** unchanged — dismissal and the per-day zone are domain state on
  the trip's SQLite→CloudKit share; no server, no new auth; the EventKit binding stays
  device-local while the reconciled outcome is shared.
- **ADR-0006:** the per-day `timeZoneIdentifier` is a flat nullable column, no version
  suffix.
- **`TripRegion` / `TripDayRegion` (ADR-0012/0013):** region is explicitly *not* the zone
  authority; it may only inform the zone as a fallback.

## Consequences

- **New shared domain state:** a per-event dismissal table (trip-scoped, fingerprint-keyed,
  dedup-on-observation) and a per-day `timeZoneIdentifier`. Both ride the existing trip
  share; the dismissal deletion/GC path reuses the constraint corroboration, not raw
  absence.
- **The reconciliation sheet becomes actionable**, not read-only: Link / Unlink / Ignore /
  Un-ignore. The model owns these mutations; the view stays thin.
- **Two-zone travel days are now legible** (own-zone display + zone tag) rather than
  silently wrong; the planner gains a real per-day zone lever independent of romance.
- **Pure-core coverage grows:** the matcher loosenings, the dismissal filter + constraint
  supersede, the zone resolver, and own-zone display formatting are all `GalavantSchema`
  logic with `GalavantSchemaTests` cases (canonical: an Eastern-departing flight on a
  CET trip; the two-Ikigai-days case; ignore/un-ignore round trip).
- **No change to** the authority boundary, the no-mirror-out rule (§11), past-trip freeze
  (§12), or the shared-identity eligibility gate.

## Slices (implementation)

Independently shippable; pure logic proven in tests before any UI. Slices 1 and 2 both
touch `CalendarExportModel` and the reconciliation rows — land them as sequential commits
to avoid a self-conflict; Slice 3 is largely separate.

- **Slice 1 — match repair.** Matcher: raw-title fallback in the exact-name rung, and
  single-unambiguous-exact-name promoted to automatic (pure, in
  `CalendarReconciliation.swift`, unit-tested). App: Link on `.proposed`/`.ambiguous`
  (picker for ambiguous) and Unlink on linked rows, reusing the `automaticPlan` durable
  path; eligibility-gated.
- **Slice 2 — permanent ignore.** New `@Table CalendarIgnoredEvent` (id, tripID,
  sourceIdentityHash, title, ignoredAt; deterministic fingerprint id). Filter before
  matching and constraint creation; supersede an existing constraint when an event is
  ignored. Reversible "Ignored" section with Un-ignore. Safety per §10. Unit-test the
  filter + supersede.
- **Slice 3 — time zones.** Own-zone display for `.absolute` events + a zone tag on the
  itinerary row (recompute from `commitmentSnapshot`; keep a canonical ordering key).
  Per-day `timeZoneIdentifier` column + resolver (override → day region → trip centroid).
  Minimal day-header affordance to set/clear a day's zone, separate from "Set region."
  Unit-test the resolver and the own-zone formatting.
- **Docs.** Update ROADMAP / CURRENT_HANDOFF / DONE_LOG and add dogfood steps to
  `docs/M7-DOGFOOD.md` (ignore + un-ignore round trip; hand-link/unlink; RDU flight shows
  Eastern with a zone tag; per-day zone override).

## Acceptance criteria

An implementation must prove: an in-scope personal note can be dismissed (no itinerary
row, no proposal), the dismissal survives relaunch and converges across two devices, and
un-dismissing restores it; a dismissed event that disappears is never treated as a
deletion decision. Both Ikigai days end linked and pinned with no manual step (raw-title
fallback + single-candidate promotion); a deliberately mis-resolved event can be
hand-linked and hand-unlinked; a wrong automatic link can be undone. An RDU→Munich flight
displays in Eastern time with a zone tag while still landing on the correct trip day; a
per-day zone override changes that day's assignment/floating interpretation without
touching other days or any region; removing all regions still leaves a working centroid
fallback.
