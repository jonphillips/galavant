# ADR-0034: The shared Apple Calendar is authoritative for real commitments; Galavant ingests and reconciles, it does not mirror out

*Status: **proposed** — 2026-08-10. Reverses the boundary of the shipped M5 calendar
slice: instead of Galavant projecting its itinerary **into** a dedicated
`Galavant: <trip>` calendar (one-way, project-never-ingest — `CalendarExport.swift`,
`CalendarExportReconciliation.swift`, `CalendarExportModel.swift`, PRs #59/#60), the
couple's **existing shared Apple Calendar** becomes authoritative for real-world
commitments, and Galavant ingests those commitments in trip scope and reconciles
them against the itinerary. This ADR decides the **authority boundary** only; the
reconciliation engine is carved into the M7 slice sequence below. Supersedes the
"project, never ingest" principle in docs/M5-EXECUTION.md; amends docs/trip-time-model.md §4
(the `.linked`/`.manual` time-authority enum). Preserves ADR-0004 (model proposes,
human decides), ADR-0001 (no server), ADR-0003 (CloudKit-shared domain state).*

## Context

Galavant's itinerary is deliberately a **planning model**: day-relative, movable,
structured (docs/trip-time-model.md §2). A trip stays day-relative for as long as
possible so it can slide on the calendar without losing its shape. Real travel
gradually hardens — flights book, reservations acquire exact dates, timed tickets
get bought — and the couple's own life (a doctor's appointment on departure day, a
call that can't move) keeps living on their **shared Apple Calendar** throughout.

That shared calendar is already an effective two-person commitment system.
Commitments arrive there through Siri, OpenTable/reservation systems, email-derived
suggestions, invitations, and direct entry — none of which route through Galavant.

The shipped M5 slice took the **opposite** boundary: Galavant created a device-local
`Galavant: <trip>` EventKit calendar, projected scheduled stops into it on demand,
never read Calendar back, and would overwrite a Calendar.app edit on the next export
(docs/M5-EXECUTION.md). That model can only ever publish a projection; it cannot see
the reservation the wife booked in OpenTable this morning. For a two-planner
household app, **ingesting reality is the valuable direction; publishing a mirror is
not.** Jon's call (2026-08-10): the shipped export code does not gate this, and the
new direction is the way.

This ADR distinguishes **planning intent** from **external commitment reality**:

- **Galavant is authoritative for trip intent and structure.**
- **The shared Apple Calendar is authoritative for the current facts of the
  commitments represented on it.**
- **Reconciliation keeps the two coherent** without pretending either system owns
  the whole itinerary.

This is not general-purpose bidirectional calendar sync. It is reconciliation
between a rich travel plan and an external commitment ledger.

## Decision

### 1. Galavant owns the plan; Calendar owns calendar-backed commitments

Galavant stays authoritative for: whether a place belongs in the trip; shortlist /
itinerary membership; conceptual day and sequence; daypart and planning preferences;
stays and geographic structure; ideas, alternatives, notes, and the overall shape.

The shared Calendar is authoritative, **while the trip is future or active**, for
the current facts of a linked commitment: that the event exists, its date, its start
and end, all-day status, time-zone / floating-time semantics, and its cancellation.

A linked Calendar event is **not** a one-time import Galavant copies and forgets.
While the trip is live, the event remains authoritative. If French Laundry moves
7:30 → 8:30, Galavant *becomes* 8:30 — it must never preserve 7:30 because it cached
that value earlier.

### 2. Ingestion is trip-scoped; every in-scope event is reckoned with

Galavant reads the shared calendar **only for a dated trip**, and only for events
that fall within or materially overlap the trip's civil-day span (§ conservative
first/last day, below). An undated / someday / targeted trip pulls **nothing** —
"only when there are trips" is native to the scope, not a separate toggle.

Within that scope, Galavant does **not** pre-classify events as "travel-related." A
flight, French Laundry, a museum ticket, a hotel, "Call Tax Advisor," a doctor's
appointment on departure day, an all-day family event — each occupies time the
itinerary must understand. Every in-scope event must eventually be either (a)
reconciled with an existing Galavant concept, or (b) represented as an
externally-originating trip constraint. There is no "ignore because it doesn't look
like travel" path.

**No privacy layer** (Jon's call, 2026-08-10): the app and the calendar are for Jon
and his wife only, never App Store. Every in-scope event becomes fully-shared
Galavant domain state — no title redaction, no busy-vs-detail split, no
opt-in-to-share. This deliberately deletes an axis of complexity a public app would
need.

### 3. Reconciliation is identity matching, not copying

When an in-scope event appears, Galavant tries to decide whether it *is* an existing
itinerary concept. `Galavant: French Laundry — Tuesday dinner` and `Calendar:
French Laundry — Tuesday 7:30 PM` should become two facets of one effective stop,
not two French Laundry stops. Matching prefers deterministic evidence (same civil
day; compatible planned daypart/time; place identity; address/coordinates;
normalized names; trip context) and **reuses the existing `PlaceMatcher` /
`PlaceMatching` ladder** (GalavantPlaces) rather than building a parallel stack.

Very strong matches link automatically; ambiguous ones become reconciliation
decisions. This ADR does not prescribe a scoring algorithm or thresholds — the M7
slices define and test them.

### 4. Authoritative changes apply automatically; only ambiguity asks a human

Galavant separates **review** from **approval**. An unambiguous authoritative change
(7:30 → 8:30) **applies automatically** and produces a durable reviewable record;
Galavant must not ask permission to accept a fact, because refusing would leave it
knowingly wrong. An unambiguous new unmatched event ("Call Tax Advisor — Wed 10:00")
becomes an external trip constraint automatically.

Humans are asked only where meaning is ambiguous: which stop a new event matches;
whether a heavily-renamed event is still the same commitment; what happens to a plan
after its reservation disappears; how to repair the itinerary after a commitment
moves; a time-zone/location ambiguity that blocks safe interpretation. This is the
ADR-0004 line held on the calendar surface: the model/engine proposes, the human
decides the *taste and plan* calls.

### 5. Reconciliation is durable shared state, not a banner

Reconciliation produces **domain state**, not an ephemeral launch notification. A
permanent surface (product name TBD — Updates / Calendar Changes / Reconciliation)
holds two independent states:

- **Review:** a change already applied correctly but unseen ("French Laundry 7:30 →
  8:30 — applied automatically — New"). Reviewing marks it seen; it does not cause
  the change.
- **Resolution:** a change that needs a decision ("French Laundry reservation
  removed — keep as an unbooked plan or remove from the trip?"). Unresolved until a
  planner addresses it.

Resolution state is **travel-party-shared**: if one planner resolves a question, the
other must not independently see it unresolved. Addressed items remain as **history**
(never destructively deleted), so the ledger explains how the trip evolved. Any
notification/badge/banner is a *pointer into* this state, never the state itself.

### 6. Provenance governs deletion

Galavant retains enough provenance to tell a concept that existed independently from
one that exists only because Calendar introduced it.

- **Galavant-originated plan + later linked commitment:** deleting the Calendar
  event removes the *booking* automatically (Calendar owns it), and Galavant asks
  the semantic question about the surviving *intention* ("keep as an unbooked plan or
  remove?"). One Calendar deletion suffices — the user is not asked to delete twice.
- **Calendar-originated constraint** ("Call Tax Advisor"): deleting the event
  removes the constraint automatically. No intention to preserve, no question.

**Rule:** Calendar-originated constraints die with their event; Galavant-originated
intentions may outlive the loss of a linked commitment.

### 7. A changed commitment may invalidate the plan without deciding the repair

If French Laundry moves Tuesday → Wednesday, Calendar has authoritatively
established Wednesday and Galavant applies it. But Calendar hasn't decided whether
Napa should follow, whether another stop drops, or whether the trip dates shift.
**Calendar determines what the commitment now is; Galavant determines how the trip
adapts around it.** Galavant surfaces the resulting itinerary conflict and helps the
planners repair it; it does not silently re-sequence.

### 8. Linked commitments may anchor the relative trip model

A day-relative itinerary is movable; a real booking is an absolute anchor. If
`Day 3 → French Laundry` matches `Calendar: Tuesday, September 15`, then `Day 3 =
Tuesday, September 15`, which constrains the trip start date — feedable into the
existing trip-date / `StartDaySolver` reasoning (ADR-0029). A commitment is a
**constraint** on the plan, not an instruction to blindly rewrite it: a conflicting
anchor surfaces an inconsistency and offers choices.

### 9. One time authority per stop: `.linked` vs `.manual`

*(This is the amend to docs/trip-time-model.md §4 and the shipped `ReservationPin` /
`TripIdea.pinnedDate` model. Jon's call, 2026-08-10.)*

Before this ADR a booked time could be represented three ways — Galavant-owned
`pinnedDate`, a linked Calendar event, and a "last reconciled snapshot" — with no
crisp owner. Collapse them into **one authority per stop**, impossible-states-gone:

- **`.manual`:** `pinnedDate` (+ the free-form `confirmationNumber` / `bookingURL` /
  `partySize`) is authoritative. A booking the user typed that has no Calendar event.
  Editable in Galavant, as today.
- **`.linked`:** a specific Calendar event is authoritative for the time. `pinnedDate`
  becomes a **read-only cache** of the last observed value, stamped with an
  observed-at instant. Galavant renders it but never treats it as editable truth;
  the next observation refreshes it. Editing the time means editing the Calendar
  event.

The exact column/representation is an M7 slice decision (extend `TripIdea`'s flat
columns per ADR-0006; the enum need not be a stored fifth thing if a nullable
"linked event identity + observed-at" already discriminates it). What this ADR fixes
is the **semantics**: exactly one authority, never a silent third truth.

### 10. Correctness invariants (first-class, not cleanup)

The engine that the M7 slices build must honor these from the start — they are where
a naive calendar integration fails catastrophically:

- **Loss of visibility is never deletion.** Permission revoked, EventKit failure,
  the account unavailable, the local binding changed, the trip range changed, the
  event outside the current query window, or sync incomplete — all mean *unknown*,
  never *deleted*. Galavant must not synthesize a destructive reconciliation from an
  inability to observe.
- **Moved-outside-trip is never deletion.** A linked commitment that moves past the
  trip window ("Sept 12 → Sept 17, trip ends Sept 15") is *moved outside the trip*
  (which may prompt extend/replan), not *deleted*. Requires enough retained identity
  to tell them apart.
- **Time zone is not the device's.** The same trip + calendar must reconcile
  identically at home, mid-trip, after crossing a zone, and after returning.
  Distinguish absolute instants / local civil date-time / civil-day-all-day values;
  never flatten Calendar's zone/floating/all-day semantics into a bare `Date`. A home
  10:00 America/New_York call constrains an Italy day at its real absolute instant
  while still showing as 10:00 Eastern. `Trip.timeZone` is insufficient for
  multi-zone trips; unresolvable civil-time interpretation becomes a reconciliation
  item, not a silent device-zone fallback.
- **Presence ≠ hard-busy.** A timed busy event is a hard occupied interval; an
  all-day event is day context (not 24h blocked); a `free` event may be relevant
  without consuming time; tentative/unavailable semantics are preserved where
  Calendar exposes them.
- **Recurrence reconciles at the occurrence level** inside the trip — never import a
  whole series; a modified occurrence is that trip-specific occurrence.
- **Trip scope includes the full first and last civil days** — a Monday-morning
  appointment matters even if the flight leaves Monday afternoon.
- **Cross-device observations deduplicate** to one shared semantic change. Both
  phones may observe the same EventKit mutation; the shared ledger must converge on
  one entry, not two. EventKit identifiers are device-local and not permanently
  stable, so the binding is device-local while the reconciled *outcome* is the shared
  CloudKit fact (ADR-0003). The identity/fingerprint algorithm is an M7 slice
  decision, explicitly not fixed here.

### 11. No automatic mirror-out; a deliberate "Add to Shared Calendar" may return later

Galavant does **not** automatically publish planned stops into the shared calendar
(the abandoned `Galavant: <trip>` mirror). A Galavant clock time is a planning
constraint, not a claim that a reservation exists — keeping the distinction
**Galavant = intention and structure / Calendar = real commitments** clean.

A future explicit **"Add to Shared Calendar"** action may be useful, and it would
reuse the shipped `CalendarExport*` write machinery — so that code isn't deleted for
cause, just demoted from "the calendar story" to one deliberate, user-invoked write.
Once such an event exists on the shared calendar it obeys the same authority and
reconciliation rules as any other commitment. General bidirectional sync stays out
of scope.

### 12. Past trips freeze into history

Calendar authority applies while a trip is future or active — it must not rewrite
history forever. On the existing trip completion/rollup lifecycle
(docs/CURRENT_HANDOFF.md trip-level done→visited rollup), Galavant does a final
reconciliation, surfaces unresolved decisions, then **freezes** the last reconciled
state into trip history. After freezing, later cleanup of old Calendar events does
not retroactively alter the completed trip; reconciliation history may remain
visible; Calendar is no longer authoritative for that trip. Reuse the trip's own
completion definition — do not invent a second one.

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **Dedicated per-device `Galavant: <trip>` mirror** (shipped M5) | Superseded. Can only publish; can never ingest the reservation booked in OpenTable/Siri; makes Galavant the sole entry path for reality. Its write machinery survives as the future §11 action. |
| **One Galavant-managed shared calendar** | Rejected. Adds a second collaborative system when Galavant already shares trip state over CloudKit and the couple already has a working shared calendar. |
| **Treat Calendar as a one-time import** | Rejected. The subsequent changes and deletions are exactly the external facts Galavant must track. |
| **Copy booking details in, then sever the link** | Rejected. Two truths, duplicate maintenance — the three-times problem §9 exists to kill. |
| **Render live Calendar events with no durable reconciliation** | Rejected. Devices would disagree on observation state; no shared outcome, no decision queue, no history/provenance. |
| **Ask the user to approve every Calendar change** | Rejected. Authoritative facts aren't proposals (§4); human attention is for ambiguity and replanning only. |
| **Treat every event as hard-busy** | Rejected. All-day/free/tentative differ from a timed commitment (§10). |
| **Reconcile historical trips forever** | Rejected. Later calendar cleanup must not rewrite completed travel (§12). |
| **Ingest + reconcile, trip-scoped, durable shared ledger, no mirror-out (chosen)** | Solves the actual two-planner workflow; keeps intent/commitment distinct; reuses `PlaceMatcher`; the hard parts (dedup, time zone) are sliced and gated, not committed up front. |

## Relationship to prior decisions

- **ADR-0004 (pull-based, model proposes / human decides):** held on this surface —
  authoritative facts auto-apply (not a taste call); plan repair and ambiguous
  matches are human decisions.
- **ADR-0001 (no server) / ADR-0003 (CloudKit-shared identity):** unchanged.
  Calendar binding is device-local; the reconciled *outcome* is shared CloudKit
  domain state; no server, no new auth.
- **ADR-0029 (`StartDaySolver`):** §8 feeds reconciled anchors into the existing
  trip-date reasoning rather than a parallel one.
- **docs/trip-time-model.md §4 (booked reservations are absolute):** amended by §9 —
  the M5-pinned principle (a confirmed booking keeps its real date when the trip
  slides) stays valid; a *linked* booking derives that date from Calendar rather than
  from an independently-editable Galavant copy.
- **M5 calendar slice / docs/M5-EXECUTION.md "project, never ingest":** superseded.
  The two-device CloudKit + image/BLOB verification in that gate is independent and
  still valid; only the calendar line is retired.

## Consequences

- **Reconciliation is materially harder than one-way export** — matching, diffing,
  temporal interpretation, and provenance all move into a tested pure core behind an
  injectable EventKit boundary (STYLE functional-core; [[inject-io-boundaries-early]]).
- **New durable shared domain state** (the reconciliation ledger) rides CloudKit —
  the first synced state whose *source* is an external system, so cross-device dedup
  (§10) is a genuine design problem, deliberately sliced last-but-one.
- **EventKit availability/permission become product-visible states** (§10), like
  sync health already is.
- **Verify EventKit against the installed SDK, not recall** — iOS 27 read/observe
  APIs, change notification, floating/all-day representation are past-cutoff
  ([[apple-sdk-headers-authoritative]]); the Slice 0 spike confirms them before code.
- **Time zone, recurrence, moved-outside-window, source-unavailable, and duplicate
  device observation are first-class test cases**, not cleanup.
- **The shipped `CalendarExport*` is retained, demoted** (§11) — no deletion for
  cause.
- **No new authentication, no CalDAV, no server-side daemon, no auto-cancellation of
  real reservations, no "is this event travel-worthy" classification, no AI-first
  matching.** Deterministic structured reconciliation first; model assistance may
  later help ambiguous semantic matching but must never silently establish a fact
  contrary to Calendar or make an irreversible plan decision.

## Slices (M7 — Calendar Reconciliation)

Riskiest-unknown-first (ROADMAP philosophy). Each is independently shippable and
testable; nothing durable/synced is written until the semantics are proven locally.

- **Slice 0 — spike (throwaway, gate).** Can we reliably observe the shared calendar
  in a dated trip's scope, match one obvious event (French Laundry) to one itinerary
  concept via `PlaceMatcher`, and survive permission-revoked + moved-outside-trip —
  **without writing any durable state**? Confirms iOS 27 EventKit reality against the
  SDK headers. Behind a small deletable entry (Jon's call, like the M6e spike). Gates
  everything.
- **Slice 1 — read-only ingest + match + local view.** Trip-scoped ingestion; the
  matching ladder + thresholds (§3); a **local** (not-yet-synced) reconciliation view.
  No auto-apply, no ledger. Proves match quality on real calendars.
- **Slice 2 — auto-apply + local history.** Unambiguous authoritative changes apply
  to linked stops (§4); the `.linked`/`.manual` authority enum (§9) lands here;
  durable **local** review/resolution history (§5).
- **Slice 3 — synced shared ledger + cross-device dedup.** Promote the ledger to
  CloudKit-shared state; the identity/fingerprint + dedup design (§10). The hard one —
  built only after 1–2 prove the semantics.
- **Slice 4 — temporal subsystem.** Time-zone three-concept model, all-day / free /
  tentative, recurrence-occurrence handling (§10) — pure core, heavily tested.
- **Slice 5 — Calendar-originated non-place constraints.** "Call Tax Advisor" as a
  trip constraint (§2) with provenance-governed deletion (§6). Simplified by the
  no-privacy-layer call — just another event kind, fully shared.
- **Slice 6 — plan-repair + anchors + freeze.** Surface itinerary conflicts from
  moved commitments (§7); feed anchors into `StartDaySolver` (§8); past-trip freeze on
  the completion lifecycle (§12).
- **Slice 7 — docs.** Flip to accepted; reconcile ROADMAP / M5-EXECUTION /
  trip-time-model / CURRENT_HANDOFF.

## Acceptance criteria

An implementation must eventually prove: planned restaurant becomes booked
(auto-link, no duplicate); reservation time change (auto-apply, one durable record);
day change (apply + surface conflict); reservation disappears (booking removed
automatically, plan pending keep/remove); Calendar-only obligation appears
(constraint, unclassified) and disappears (removed, no redundant question); two-device
observation (one shared change); permission failure (no inferred deletion);
moved-outside-trip (reported as moved, not deleted); time-zone stability (identical at
home and abroad); home-zone appointment abroad (constrains at the real instant);
all-day/free (no false 24h block); recurring occurrence (independent of the series);
trip-date reasoning (anchor constrains start without silent rewrite); durable inbox
(applied changes inspectable after relaunch; unresolved stay outstanding); post-trip
freeze (later event deletion doesn't alter history).
