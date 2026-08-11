# ADR-00XX: Reconcile the Shared Calendar as the Authority for Real-World Commitments

**Status:** Proposed
**Date:** 2026-08-10

## Context

Galavant’s itinerary is intentionally a planning model.

A trip begins as a conceptual structure: places worth visiting, restaurants worth eating at, stays, travel legs, sequencing, relative days, dayparts, and clock-time planning constraints. The itinerary remains day-relative for as long as possible so that a trip can move on the calendar without destroying its internal structure.

Real travel gradually becomes less hypothetical. Flights are booked. Restaurant reservations acquire exact dates and times. Timed tickets are purchased. Personal obligations remain on the couple’s shared Apple Calendar even while traveling.

Apple Calendar is already an effective collaborative commitment system for the two planners. Events may arrive there through direct entry, Siri, invitations, reservation systems, email-derived suggestions, or other Apple integrations. Requiring those commitments to originate in Galavant and then be mirrored back to Calendar would duplicate a system that already works well and would create two independently editable representations of the same reality.

The previously designed M5-calendar approach proposed the opposite boundary: Galavant would create a dedicated local `Galavant Travel` calendar, project itinerary stops into it, never ingest Calendar events, and overwrite Calendar edits during reconciliation.

That model is superseded by this ADR.

The new model distinguishes **planning intent** from **external commitment reality**:

- **Galavant is authoritative for trip intent and structure.**
- **The designated shared Apple Calendar is authoritative for real-world commitments represented on that calendar.**
- **Reconciliation keeps those two worlds coherent without pretending that either system exclusively owns the entire itinerary.**

This is not general-purpose bidirectional calendar synchronization.

It is reconciliation between a rich travel plan and an external commitment ledger.

## Decision

### 1. Galavant owns the plan; Calendar owns calendar-backed commitments

Galavant remains authoritative for:

- whether a place belongs in the trip;
- shortlist and itinerary membership;
- conceptual day and sequence;
- daypart and other planning preferences;
- stays and geographic structure;
- alternatives and ideas;
- notes and trip-specific context;
- the broader shape of the trip.

The designated shared Calendar is authoritative for the current facts of commitments represented there, including:

- existence of the event;
- date;
- start and end time;
- all-day status;
- time-zone/floating-time semantics;
- cancellation or deletion;
- other Calendar-supplied commitment facts that Galavant elects to use.

A linked Calendar event is not merely evidence from which Galavant permanently copies a booking. While the trip is future or active, the Calendar event remains authoritative for that commitment.

Example:

Galavant initially contains:

> The French Laundry — Day 3, dinner

The shared Calendar later contains:

> The French Laundry — Tuesday, 7:30 PM

Reconciliation links the two. Galavant may now render the item as a booked 7:30 PM commitment, but 7:30 PM is owned by the linked Calendar event.

If the event later changes to 8:30 PM, Galavant becomes 8:30 PM.

Galavant must never preserve 7:30 PM merely because it imported or cached that value earlier.

### 2. Every shared-Calendar event during a dated trip must be reckoned with

The selected Calendar is the couple’s existing **shared calendar**, not a travel-specific calendar.

Therefore Galavant must not attempt to classify Calendar events as “travel-related” before considering them.

For a dated trip, every occurrence on the designated shared Calendar that falls within or materially overlaps the trip’s calendar scope must be accounted for.

Examples include:

- a flight;
- The French Laundry;
- a museum ticket;
- a hotel commitment;
- “Call Tax Advisor”;
- a doctor appointment on departure day;
- an all-day family event.

“Call Tax Advisor” may have no travel semantics, but it occupies time that Galavant must understand when evaluating that day’s itinerary.

An event within scope must eventually be either:

1. reconciled with an existing Galavant concept; or
2. represented as an externally originating trip constraint.

There is no “ignore because this does not look like travel” path for an event on the designated shared Calendar.

### 3. Reconciliation is identity matching, not copying

When a new Calendar event appears, Galavant attempts to determine whether it corresponds to an existing itinerary concept.

For example:

> Galavant: The French Laundry — Tuesday dinner
> Calendar: The French Laundry — Tuesday 7:30 PM

These should become two facets of the same effective itinerary item, not two independent French Laundry stops.

Matching should prefer deterministic evidence where available:

- same civil day;
- compatible planned daypart/time;
- place identity;
- address or coordinates;
- normalized names;
- known trip context;
- other structured Calendar metadata.

Existing Galavant place-matching machinery should be reused where applicable rather than building a parallel matching stack.

Matching confidence is not itself permission to rewrite ambiguous meaning. Very strong matches may be linked automatically. Ambiguous matches become reconciliation decisions.

The eventual implementation should define explicit confidence/decision thresholds and test them. This ADR does not prescribe a particular scoring algorithm.

### 4. Authoritative changes apply automatically; ambiguity requires a decision

Galavant must distinguish **review** from **approval**.

If a linked Calendar event unambiguously changes:

> French Laundry 7:30 PM → 8:30 PM

8:30 PM applies automatically.

Galavant must not ask whether to “accept” an authoritative Calendar fact. Refusing would leave Galavant knowingly wrong.

Likewise, an unambiguous new unmatched Calendar event such as:

> Call Tax Advisor — Wednesday 10:00 AM

becomes an external trip constraint automatically.

Human resolution is required only where meaning remains ambiguous, for example:

- which Galavant item a new event matches;
- whether a substantially renamed event is still the same commitment;
- what should happen to an underlying Galavant plan after its reservation disappears;
- how to repair the conceptual itinerary after a commitment moves;
- a time-zone/location ambiguity that prevents safe interpretation.

### 5. Reconciliation has a durable shared inbox and history

Calendar reconciliation must not be represented solely by a launch notification, transient banner, alert, sheet, or other ephemeral UI.

Reconciliation produces **durable domain state**.

Galavant must provide a permanent location where the planners can inspect Calendar-driven changes and unresolved decisions.

The product presentation may be called **Updates**, **Calendar Changes**, **Reconciliation**, or similar; naming is a UX decision.

Two independent states matter:

#### Review state

A change may already have been applied correctly but remain unseen:

> French Laundry moved 7:30 PM → 8:30 PM
> Applied automatically
> New

Reviewing it marks it seen. It does not approve or cause the change.

#### Resolution state

Some changes genuinely require a decision:

> French Laundry reservation was removed.
> Booking state removed automatically.
> Keep French Laundry as an unbooked plan, or remove it from the trip?

Such an item remains unresolved until one planner addresses it.

Reconciliation state is travel-party-shared. If one planner resolves a semantic question, the other planner should not independently receive the same question as unresolved.

Both planners’ devices may observe the same Calendar mutation. The implementation must deduplicate those observations into one shared semantic change rather than producing duplicate inbox entries.

Addressed entries should remain available as history rather than being destructively deleted. The ledger should make it possible to understand how the trip evolved:

> Reservation found at 7:30
> Reservation moved to 8:30
> Reservation removed
> Kept as unbooked plan
> New reservation found at 8:00

Transient notifications or launch summaries are pointers into this durable state, never the state itself.

### 6. Provenance determines deletion semantics

Galavant must retain enough provenance to distinguish a concept that existed independently in Galavant from one that exists only because Calendar introduced it.

#### Galavant-originated plan with later Calendar commitment

Galavant contains:

> The French Laundry — Tuesday dinner

Calendar later supplies a linked reservation.

If the Calendar event is deleted, the booking disappears automatically because Calendar owns the commitment.

The underlying intention does not necessarily disappear.

Galavant records the change and asks the semantic question:

> The French Laundry reservation was removed.
> Keep as an unbooked plan or remove from the trip?

Deleting the reservation from Calendar is sufficient to remove the reservation from Galavant. The user is not being asked to “delete it twice”; the remaining decision concerns the independent planning intention.

#### Calendar-originated constraint

Calendar supplies:

> Call Tax Advisor — Wednesday 10:00 AM

No independent Galavant concept existed before it.

If that Calendar event is subsequently deleted, its Galavant constraint disappears automatically. There is no planning intention to preserve.

**Rule:** Calendar-originated constraints die with their Calendar event. Galavant-originated intentions may survive loss of a linked Calendar commitment.

### 7. A changed commitment may invalidate the plan without deciding how to repair it

Suppose French Laundry moves:

> Tuesday 7:30 PM → Wednesday 7:30 PM

Calendar has authoritatively established Wednesday.

Galavant applies that fact.

But Calendar has not answered whether:

- Napa should move to Wednesday;
- Sonoma should move elsewhere;
- another stop should be dropped;
- the trip dates should shift.

Those are planning questions and remain Galavant’s responsibility.

Galavant should surface the resulting itinerary conflict and help the planners repair it.

This separation is fundamental:

> **Calendar determines what the commitment now is. Galavant determines how the trip should adapt around it.**

### 8. Calendar commitments may anchor Galavant’s relative trip model

Galavant’s day-relative itinerary is deliberately movable.

A real booking can supply an absolute anchor.

Example:

> Galavant: The French Laundry on Day 3
> Calendar: The French Laundry on Tuesday, September 15

If matched, the combination implies:

> Day 3 = Tuesday, September 15

and therefore constrains the possible trip start date.

Galavant may use one or more reconciled commitments as inputs to its existing trip-date/start-day reasoning.

A commitment does not silently rewrite the entire conceptual itinerary. If an external anchor conflicts with the current trip dates or with another commitment, Galavant surfaces the inconsistency and offers planning choices.

Real commitments are constraints on the plan, not instructions to blindly mutate it.

### 9. Time-zone semantics are first-class

This reconciliation model must never depend implicitly on the device’s current time zone.

The same Calendar state and Galavant trip must reconcile identically whether the operation runs:

- at home before departure;
- while traveling;
- after crossing a time zone;
- after returning home.

Galavant must distinguish at least three temporal concepts:

1. **Absolute instants** — real points on the timeline.
2. **Local civil date/time** — “Tuesday at 7:30 PM” in a particular time zone.
3. **Civil days/all-day values** — which must not be naïvely treated as midnight instants and shifted between zones.

Calendar-provided time-zone, floating-time, and all-day semantics must be preserved rather than flattened into an unqualified `Date`.

#### Local presentation versus occupied time

Conflict detection for absolute timed commitments operates on real instants.

Human itinerary presentation uses the appropriate local travel context.

Example:

> Call Tax Advisor — 10:00 AM America/New_York

while the traveler is in Italy may occupy:

> 4:00 PM Europe/Rome

Galavant should constrain the Italy itinerary at the corresponding local instant, while retaining enough provenance to show that the appointment itself is 10:00 AM Eastern.

#### Multi-time-zone trips

A single `Trip.timeZone` is not sufficient as a universal solution because trips can cross zones and even a single travel day can do so.

Relevant place/location information should determine local presentation where possible.

If Galavant cannot safely determine the civil-time interpretation needed for reconciliation, that ambiguity becomes a reconciliation item rather than silently falling back to the device time zone.

### 10. All-day, free, and recurring events are still reconciled but have distinct constraint semantics

Every in-scope shared-Calendar event must be reckoned with, but not every event blocks the itinerary in the same way.

Examples:

- a normal timed busy event is a hard occupied interval;
- an all-day event is day context and does not automatically mean 24 hours unavailable;
- an event explicitly marked free may be relevant without consuming the interval as hard unavailable time;
- tentative/unavailable semantics should be preserved where Calendar exposes them.

Presence and constraint strength are separate concepts.

Recurring Calendar events reconcile at the **occurrence** level within the trip, not by importing an entire recurrence series into Galavant.

A modified occurrence is treated as that trip-specific occurrence.

### 11. Trip scope includes the full first and last trip days

If Monday is a trip day, a Monday-morning shared Calendar appointment matters even when the flight does not leave until Monday afternoon.

Likewise, obligations later on the return day may constrain what can happen before or after arrival.

For reconciliation purposes, the trip’s first and last civil days are included conservatively rather than trying to infer an exact instant at which “the trip begins” or “the trip ends.”

The timezone rules above govern how events are evaluated against those days.

### 12. Calendar binding is local; reconciliation results are shared

The identity of the EventKit calendar available on a particular device is a device-local integration concern.

Each planner/device may need to bind its locally visible Calendar representation of the couple’s shared calendar.

Do not assume that a device-local EventKit calendar identifier is itself suitable shared CloudKit domain identity.

What **does** become shared Galavant state includes the semantic outcome:

> French Laundry is currently booked Tuesday at 8:30 PM

and the durable reconciliation history surrounding it.

Thus one planner’s device can observe an authoritative change and propagate the reconciled trip fact through Galavant’s existing shared data model. The second device should deduplicate its own subsequent observation of the same external change rather than create another semantic event.

The implementation must retain enough Calendar identity/fingerprint information to:

- reconnect observations to known commitments;
- tolerate identifiers that are not permanently stable;
- distinguish an event moved outside the trip from a deleted event;
- avoid regressing a newer observation with stale data from another device.

This ADR deliberately does not prescribe the storage shape or fingerprint algorithm.

### 13. Loss of Calendar visibility is never deletion

Galavant may treat a Calendar event as deleted only after a successful observation establishes its absence or cancellation under conditions where that conclusion is valid.

The following are **not** evidence of deletion:

- Calendar permission is revoked;
- EventKit access fails;
- the selected Calendar account is unavailable;
- the local Calendar binding changes;
- the trip date range changes;
- the trip is shortened;
- the event falls outside the current query window;
- synchronization is otherwise incomplete or unknown.

In those cases Calendar state is unknown or out of scope.

Galavant must not synthesize destructive reconciliation from inability to observe the source.

### 14. Movement outside the trip is not deletion

If a known linked commitment moves outside the current trip window, Galavant must distinguish that from deletion.

Example:

> French Laundry moves from September 12 to September 17
> Trip currently ends September 15

The correct semantic event is:

> French Laundry reservation moved outside the trip.

That may lead to decisions about extending the trip, removing the plan, or otherwise replanning.

It must not be reported merely as “French Laundry deleted.”

The implementation must retain sufficient identity and perform sufficient targeted lookup to preserve this distinction.

### 15. Galavant does not automatically mirror its itinerary into Calendar

The prior M5-calendar proposal for a dedicated `Galavant Travel` mirror is abandoned.

Galavant must not automatically publish planned itinerary stops into the shared Calendar.

This preserves the useful semantic distinction:

> **Galavant = intention and structure**
> **Calendar = real commitments**

A Galavant clock time can still be a strong planning constraint without claiming that a real reservation exists.

A future explicit action such as **Add to Shared Calendar** may be useful, but it must be a deliberate user operation rather than automatic mirroring.

Once a corresponding event exists on the designated shared Calendar, that event participates in the same authority and reconciliation rules as any other Calendar commitment.

General-purpose bidirectional synchronization remains out of scope.

### 16. Past trips freeze into history

Calendar authority is appropriate while commitments are still part of a future or active trip.

It must not rewrite historical reality forever.

After a trip is completed, Galavant freezes the last reconciled commitment state into trip history. Subsequent cleanup or deletion of old events from Apple Calendar must not retroactively erase or alter what happened on the completed trip.

The exact freeze trigger should integrate with Galavant’s trip-level post-trip completion/rollup lifecycle rather than creating an unrelated second definition of trip completion.

Before freezing, Galavant should perform a final reconciliation and surface unresolved semantic decisions.

After freezing:

- linked Calendar state becomes historical Galavant state;
- the historical trip no longer tracks subsequent Calendar mutations;
- reconciliation provenance/history may remain visible;
- Calendar is no longer authoritative for that completed trip.

## Reconciliation model

At a product-semantics level, the engine behaves approximately as follows:

| Calendar observation | Galavant state | Semantic result |
|---|---|---|
| New event, obvious match | Existing plan | Auto-link and apply commitment facts |
| New event, ambiguous match | One or more plausible plans | Create unresolved reconciliation item |
| New event, no match | No corresponding concept | Create Calendar-backed trip constraint |
| Linked event changes time | Existing linked item | Apply automatically; record change |
| Linked event changes day | Existing linked item | Apply automatically; flag resulting itinerary conflicts |
| Linked event changes identity materially | Existing linked item | Require semantic rematch |
| Linked event deleted | Galavant-originated plan | Remove commitment; ask whether plan survives |
| Linked event deleted | Calendar-originated constraint | Remove constraint automatically |
| Linked event moves outside trip | Existing linked item | Record moved-outside-trip conflict |
| Calendar becomes unreadable | Any | Mark observation unavailable; do not infer change |
| Duplicate observation from second planner/device | Existing reconciliation event | Deduplicate |
| Trip completed | Reconciled state | Freeze into history |

## Relationship to existing Galavant time semantics

This ADR preserves the existing distinction between:

- day-relative planning; and
- absolute booked reality.

It does not reintroduce absolute dates into the general `Schedule` facade.

The M5-pinned design’s principle remains valid: a confirmed commitment must stay on its real calendar date when the trip’s relative start date moves.

However, this ADR refines ownership of that absolute state:

- a manually recorded non-Calendar booking may still need Galavant-owned absolute booking data;
- when a booking is linked to the designated shared Calendar, the Calendar event is authoritative while the trip is live;
- any persisted Galavant booking snapshot must therefore be understood as the last reconciled external state, not an independently editable competing truth.

Implementation should inspect the current `TripIdea`, freeform-stop, `TripStay`, `TripPlan`, and trip-time machinery before deciding whether Calendar-backed constraints require new persistence or can extend existing concepts cleanly.

Do not create parallel machinery where existing itinerary abstractions suffice.

## Reconciliation Inbox requirements

The eventual UI must provide:

- a permanent location for reconciliation history;
- an unread/new count;
- a separate unresolved/needs-decision count;
- trip association for every item;
- readable before/after descriptions for material changes;
- automatic-change history;
- explicit resolution actions for ambiguity;
- shared resolution state across the travel party;
- deduplication across multiple observing devices;
- enough provenance to explain why the current itinerary has its present state.

A launch-time summary, badge, notification, or banner may improve discoverability, but dismissing that UI must never discard reconciliation state.

## Non-goals

This ADR does **not** define:

- a dedicated Galavant-owned Apple Calendar;
- continuous Galavant→Calendar itinerary mirroring;
- general bidirectional Calendar synchronization;
- calendar sharing or CalDAV provisioning;
- automatic cancellation or modification of real reservations;
- classification of whether a shared Calendar event is “travel worthy”;
- a server-side calendar daemon;
- a new authentication system;
- the exact database schema for reconciliation records;
- the exact EventKit identity/fingerprint algorithm;
- the exact matching score or fuzzy-name algorithm;
- an AI-first matching system.

Deterministic structured reconciliation should be preferred wherever possible. Model assistance may later help with ambiguous semantic matching, but it must not silently establish external facts contrary to Calendar or make irreversible planning decisions.

## Supersedes / amends

This ADR **supersedes the M5-calendar design** in `docs/M5-EXECUTION.md`, specifically:

- the dedicated local `Galavant Travel` calendar;
- the “project, never ingest” principle;
- Calendar as read-only output;
- stomping Calendar edits back to Galavant state;
- per-trip continuous mirror reconciliation.

The old M5-calendar execution brief should not be implemented as written.

This ADR **preserves but amends M5-pinned**:

- confirmed bookings remain absolute facts;
- relative planning remains relative;
- absolute commitments remain outside the `Schedule` facade;
- but a Calendar-linked commitment derives its live authoritative state from Calendar rather than from an independently authoritative Galavant copy.

`docs/CURRENT_HANDOFF.md`, `docs/ROADMAP.md`, `docs/M5-EXECUTION.md`, and `docs/trip-time-model.md` should be updated when this ADR is accepted so that they no longer point future work toward the superseded mirror design.

## Consequences

### Positive

- Siri and the Apple ecosystem can continue to create commitments naturally in the existing shared Calendar.
- Either planner can make bookings without first entering them through Galavant.
- Galavant gains awareness of real-world obligations without attempting to replace Calendar.
- Conceptual trip planning remains flexible before bookings arrive.
- Real bookings progressively anchor the flexible plan to reality.
- Personal commitments such as calls and appointments become visible scheduling constraints.
- Calendar deletion/change requires only one action; Galavant reconciles rather than demanding duplicate maintenance.
- The two-planner shared-data architecture remains centered on Galavant/CloudKit rather than adding shared-calendar infrastructure owned by Galavant.
- Historical trips remain stable after completion.
- Time-zone behavior is explicit rather than accidentally dependent on the device location.

### Costs

- Reconciliation is materially more sophisticated than one-way export.
- Cross-device observation deduplication requires careful identity/provenance design.
- EventKit availability and permission state become product-visible integration states.
- Calendar event identity is not sufficient by itself; semantic fingerprinting/recovery is required.
- Time-zone, all-day, recurrence, and moved-outside-window behavior require extensive pure-core tests.
- Calendar-originated non-place commitments may expose gaps in the current itinerary representation.
- A durable reconciliation ledger introduces persistent shared domain state rather than merely transient integration logic.
- The resulting planning engine must distinguish authoritative external change from the Galavant decisions required to accommodate that change.

These costs are accepted because they solve the actual two-planner workflow rather than maintaining a duplicate calendar projection.

## Rejected alternatives

### Dedicated per-device `Galavant Travel` calendar

Rejected.

It reproduces the itinerary in Calendar but cannot naturally ingest commitments created by Siri, reservation systems, or the planners’ existing shared Calendar. It also makes Galavant the only accepted entry path for reality.

### One Galavant-managed shared calendar

Rejected.

It introduces another collaborative data system when Galavant already shares trip state and the couple already has a working shared Calendar.

### Treat Calendar as a one-time import source

Rejected.

Once an event is linked, subsequent changes and deletions are precisely the external facts Galavant must know about.

### Copy booking details into Galavant and then sever the Calendar relationship

Rejected.

This creates two truths and forces duplicate maintenance.

### Render live Calendar events without durable Galavant reconciliation

Rejected.

Different devices may have different observation state; there would be no shared semantic outcome, no durable decision queue, and no provenance/history.

### Ask the user to approve every Calendar mutation

Rejected.

Authoritative external facts are not proposals. Human attention is reserved for semantic ambiguity and replanning choices.

### Treat all Calendar events as hard busy intervals

Rejected.

Every event must be accounted for, but all-day/free/tentative semantics differ from a normal timed commitment.

### Continue reconciling historical trips indefinitely

Rejected.

Later calendar cleanup must not rewrite completed travel history.

## Acceptance criteria

An implementation conforming to this ADR must prove at least the following scenarios:

1. **Planned restaurant becomes booked**
   French Laundry exists as Tuesday dinner in Galavant; a Tuesday 7:30 Calendar reservation appears; Galavant reconciles them without creating a duplicate stop.

2. **Reservation time changes**
   Calendar moves 7:30 → 8:30; Galavant updates automatically and creates one durable reviewable change.

3. **Reservation day changes**
   Calendar moves Tuesday → Wednesday; Galavant applies Wednesday and surfaces any resulting itinerary conflict.

4. **Reservation disappears**
   Calendar deletion immediately removes booking authority. A preexisting Galavant plan remains pending a keep/remove decision.

5. **Calendar-only obligation**
   “Call Tax Advisor” appears during the trip; it becomes an itinerary constraint without being classified as travel.

6. **Calendar-only obligation disappears**
   Removing that event removes the Calendar-originated constraint without a redundant user decision.

7. **Two-device observation**
   Both planners observe the same Calendar mutation; shared Galavant state contains one semantic reconciliation change.

8. **Permission failure**
   EventKit becomes unavailable; Galavant does not interpret existing commitments as deleted.

9. **Moved outside trip**
   A linked reservation moves beyond the current trip dates; Galavant reports movement outside the trip rather than deletion.

10. **Time-zone stability**
    The same trip reconciles identically when the device is in North Carolina and when it is in Europe.

11. **Home-zone appointment while abroad**
    A 10:00 AM America/New_York call correctly constrains the itinerary at its corresponding absolute time in the destination’s local context.

12. **All-day/free semantics**
    Such events appear in reconciliation without incorrectly blocking a full 24-hour day.

13. **Recurring occurrence**
    One occurrence inside the trip reconciles independently of the recurrence series.

14. **Trip-date reasoning**
    An absolute reservation corresponding to Day 3 can constrain/flag the trip start date without silently rewriting the conceptual itinerary.

15. **Durable inbox**
    Automatically applied changes remain inspectable after dismissal/relaunch; unresolved changes remain outstanding until addressed.

16. **Post-trip freeze**
    After the trip’s completion/final reconciliation, later deletion of the old Calendar reservation does not alter historical Galavant state.

## Implementation guidance

Before implementation:

1. Read the current `AGENTS.md` and the house architecture guidance referenced there.
2. Re-read the current trip/time ADRs and `docs/trip-time-model.md`.
3. Inspect live `Trip`, `TripIdea`, `TripStay`, `Schedule`, freeform-stop, `TripPlan`, CloudKit sync, navigation, and device-local settings implementations.
4. Determine whether existing abstractions can represent Calendar-backed non-place constraints and reconciliation history before adding new domain types.
5. Keep EventKit behind an injectable I/O boundary; put matching, diffing, temporal interpretation, and reconciliation semantics into testable pure core where practical.
6. Verify current EventKit APIs against the installed SDK rather than relying on remembered API behavior.
7. Treat timezone, recurrence, deletion, movement outside the query window, duplicate device observations, and source-unavailable behavior as first-class test cases rather than cleanup work.

The implementation brief should be written from the live codebase after this ADR is accepted. This ADR specifies behavior and authority boundaries; it intentionally does not pre-design schema that the current architecture may already know how to express.