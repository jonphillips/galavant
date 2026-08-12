# ADR-0035: Itinerary alternatives — a ring of stops sharing one slot, exactly one active

*Status: proposed — 2026-08-12. **Twice-reframed the same day.** Draft 1 was a symmetric
"choice" (two co-equal candidates, one eventually chosen, **undecided** until then); draft 2 an
asymmetric **primary + backup**. The clarifying insight, reached via a "cycle through the
alternatives" interaction: the expensive part was never the *grouping* — it was the **undecided
state**, which forced a read-model collapse fold inside the tested leg/numbering core and an
"acknowledge uncertainty" routing gap. Mandate **exactly one active member at all times** and
both vanish, while the members stay **co-equal peers** you rotate through — which fits the
product better than a designated primary. Extends ADR-0010 (freeform stops) and ADR-0033
(floating untimed stops); rides ADR-0007 (single-FK / reconcile-on-read) and ADR-0006 (flat
`TripIdea` columns). Composes with ADR-0029 (`StartDaySolver`) and M7 (calendar reconciliation)
— an alternative is the ready-made fix when the active stop fails a constraint. Prompted by a
real Dolomites plan: lunch at **Baita Sanon Hütte** *or* **Gostner Schwaige** — today only
expressible as two sequential stops, which fabricates a phantom travel leg between them.*

## Context

The itinerary is a **flat list of `TripIdea` rows** projected into a linear day. Two of those
projections make a day read as a line, and both are derived from **list adjacency**:

1. **Travel legs are zipped over consecutive located stops.** `TripPlan.legs(forDay:)`
   (GalavantSchema/TripPlan+Travel.swift:20) and the connector weave in
   `TripPlan.itineraryItems(forDay:)` (TripPlan.swift:416) do `zip(stops, stops.dropFirst())`
   over the day's located stops. Put Baita and Gostner adjacent in the list and the model
   **automatically emits a Baita→Gostner leg** with an ETA — the falsehood we must not print.

2. **Pin/sequence numbers are positional.** `TripPlan.locatedSequenceNumbers(forDay:)`
   (TripPlan.swift:312) numbers located stops by `enumerated()` position — two stops eat two
   numbers.

The product need is narrow: *one itinerary position offers a few interchangeable options, one of
which is the plan right now.* "Lunch is Baita — or cycle to Gostner and see how the day
re-routes."

**The design decision, arrived at over two reframings.** Draft 1 modeled this as a *symmetric
choice* with an **undecided** state (nothing chosen until you decide). That undecided state is
what forced the machinery: both candidates sat *in* the day sequence, so every positional
projection (`legs`, `locatedSequenceNumbers`, the weave) had to **collapse** the group to one
slot; and because "chosen" could be empty, routing needed an "acknowledge uncertainty, omit the
leg" branch. Draft 2 removed the undecided state by making one option a **primary** and the rest
off-sequence **backups** — clean, but asymmetric, imposing a canonical "real plan" the product
doesn't need and making a *cycle* interaction rotate an awkward star of pointers.

The chosen model keeps draft 2's winning property — **exactly one option is active; the rest are
off-sequence** — but treats the options as **co-equal peers in a ring**, not primary-plus-lessers.
A single flag says which peer is active; a **cycle** advances it; a **disclosure** on the row
reveals the whole ring. This is **not** a branching graph, and it is distinct from **Ideas**
(under consideration, not on the itinerary) and **optional/skippable stops** (dropped entirely,
no "instead"). It solves exactly: *this slot has a few interchangeable options, one active.*

**Two moods, one mechanism (firmness-keyed presentation).** The ring covers two real situations
that feel different but *are* the same object: a **committed slot with a fallback** ("lunch is
Baita, backup Gostner") and an **open block with a menu** ("open afternoon — here are four things,
what are we in the mood for?"). The only difference is *firmness*, which Galavant already models
as the slot's schedule — so the ring inherits its mood from the slot rather than a new label. A
**routed slot** (firmly scheduled) shows a **current pick + alternatives** and keeps *exactly one*
member active; a **loose slot** (Anytime/unscheduled, ADR-0033) renders the ring **neutrally** —
peers, no emphasized pick — and allows *zero-or-one* active, because nothing routes through it.
The user never declares "backup" vs "consideration"; they drop options on a slot and decide when
ready. Splitting these into two features would encode a *mood* as a type — the thing to resist.

## Decision

**An alternatives group is a set of `TripIdea` stops that share one itinerary slot, with exactly
one member `isActive`.** The active member is an ordinary sequenced stop; the inactive members
are off-sequence and never enter the route. There is no undecided state — cycling only ever moves
*which* peer is active.

### 1. Two additive flat columns on `TripIdea`

Per ADR-0006 (flat columns) and ADR-0007 (the one real FK is to `Trip`; everything else is a
loose, reconcile-on-read UUID):

```swift
public var alternativeGroupID: UUID?   // nil = ordinary stop; shared by a ring's members
public var isActive = true             // the one member of the ring shown in the day
```

- **`alternativeGroupID`** is a loose UUID (like `ideaID`), shared by a ring's members, reconciled
  on read. An ordinary stop has `nil` and `isActive == true` (it is trivially "the active member
  of a ring of one" — so the common path needs no special-casing).
- **`isActive`** — on a **routed** (firmly scheduled) slot, **exactly one** member is true; on a
  **loose** (Anytime/unscheduled) slot, **at most one** (a neutral menu may sit with none active).
  There is never a "nobody active" state on a *routed* slot — draft 1's expensive case — and it
  stays gone. Invariant enforced by the ops (§4).
- **Members share the slot.** Every member of a ring carries the *same* `dayNumber`, `schedule`,
  and `dayRank` (ADR-0033) — they occupy one position. So **cycling never moves slot data**; it
  only flips `isActive`. Order *within* the ring (for a predictable cycle) uses the members'
  existing `shortlistRank`.

Both columns ride `TripIdea`'s existing CloudKit registration — **no sync-registration change**.

### 2. Inactive members are off-sequence — the tested linear core is untouched

The read-model keeps only the **active** member of each group in the day, at the one partition
boundary it already has:

- `TripPlan.scheduled`, `TripIdea.itinerary`, and `TripIdea.toBeScheduled` each add `&& isActive`
  to their existing `status == .scheduled` filter. An inactive member never lands in a day, the
  To-Be-Scheduled bucket, or the Ideas "Scheduled" section.
- A new projection `alternatives(forStop: TripIdea.ID) -> [ResolvedStop]` returns a stop's ring
  (all members, active first), for the disclosure UI.

**Because inactive members are never in the day's stop list, `legs`, `locatedSequenceNumbers`,
`framingCoordinates`, and the `itineraryItems` weave never see them** — with *zero* changes to
any of them. The active member flows through every one exactly as an ordinary stop does today.
There is **no collapse fold**, and the phantom Baita→Gostner leg is **structurally impossible**:
the two are never both in the routed sequence (AC #3, met for free rather than enforced).

### 3. Routing is always concrete — no uncertainty branch

On a **routed** slot the route runs `prev → active → next` — exactly one member is active, so
there is no "omit the leg / acknowledge uncertainty" case (draft 1's thorniest sub-case, gone). A
**loose** slot with no active member contributes **no routed stop**; the app navigates around it
exactly as it already does for any Anytime/timing-neutral stop (ADR-0033 §4) — no leg, no ETA.
This **reuses shipped behavior rather than re-introducing the fold**: every member of a loose
slot is *off*-sequence, so there is nothing to squash (the fold was about squashing members that
sat *in* the routed sequence). `baseLegs` / lodging routing is unchanged.

### 4. Cycle / set-active — a flag flip, works mid-trip

Selection is a single tested op, not a read-model resolution, and — because members share the
slot — it **never copies slot columns**:

- `cycleAlternative(_:)` — advance `isActive` from the current member to the **next in the ring**
  (by `shortlistRank`, wrapping). The quick "just show me the other one" gesture.
- `setActiveAlternative(_:)` — make a **specific** member active (the disclosure's tap-to-choose).
- `promoteAlternative(_:)` — the **mirror of `addAlternative`**: pull a member **out** of the ring
  into its own standalone, routed stop (clear its `alternativeGroupID`, place it at its own
  position on the day). Because add/remove already exist, promote is the same machinery run
  backwards; and a ring left with one member reconciles to an ordinary stop (§6), so promoting
  naturally dissolves the ring once you've decided.

The first three are two flag writes; none copies slot columns. The routing, ETAs, pin position,
and start-day/reconciliation checks all recompute downstream because the active member's
coordinates changed — **no preview is computed or needed** (the user cycles and sees the real
re-routed day). Runnable during the trip (AC #4, #5). **Promote is what lets a neutral menu
resolve gracefully:** you needn't pick one and lose the rest — do one in the moment
(`setActive`), or promote one **or several** into the real plan and drop the others ("we'll do
the market *and* the castle"). A promoted stop lands on the same day beside its old slot and is
scheduled like any stop.

### 5. UI: one active row, a disclosure to the ring, a cycle control

- **Timeline (`TripItineraryView`):** a **routed** slot renders as its **active** member — an
  ordinary numbered row — carrying a small **"N of M"** badge with a **cycle** (⟳) control and a
  **disclosure arrow**; a **loose** slot renders **neutrally** (e.g. "Open afternoon — 4 ideas")
  with the same disclosure but no emphasized pick. Expanding reveals the ring — the **current
  choice** highlighted (routed) or the options as peers (loose) — where you tap to make one active
  (`setActiveAlternative`), **promote** one into the itinerary (`promoteAlternative`), or **add /
  remove** options. It is never a second *sequential* row — the ring lives inside one slot.
- **Canvas:** the active member wears its ordinary numbered pin; the inactive alternatives draw
  **only while the row's disclosure is expanded (or the stop is selected)**, as muted, unnumbered
  pins, contributing **no** polyline segment (AC #2, #3).
- **Creation is contextual:** **"Add as alternative to…"** on a shortlisted idea, or **"Add
  alternative"** on a stop, in `StopMenu` (Galavant/Trips/StopMenu.swift) — it mints/joins the
  `alternativeGroupID` and copies the slot onto the new member (inactive).

### 6. Deletion & orphans

- Deleting the **active** member makes the next member in the ring active in the same write, so
  the slot survives; deleting an **inactive** member just removes it. A ring reduced to **one**
  member reconciles back to an ordinary stop (clear `alternativeGroupID`).
- A member **orphaned** by a cross-device group dissolution (its `alternativeGroupID` no longer
  names a live ring, or a race leaves *no* active member) reconciles on read: the lowest-`shortlistRank`
  member is treated as active, the rest surface as its ring — **recoverable, never silently
  dropped** — the same reconcile discipline `resolve(_:)` applies to a deleted `ideaID`
  (TripPlan.swift:128).

### 7. What we explicitly do **not** build

No undecided state on a **routed** slot (a firm position always has an answer — §Why not); no
branching/convergence; no optional/skippable concept; no cross-alternative route optimization; no
routing *preview* (you cycle and see the real day). A **loose** slot's neutral menu is **not** the
draft-1 undecided state — nothing routes through it, so it costs nothing. The Ideas pool stays the
home for "maybe someday" — a ring member is a *scheduled* option for a specific slot.

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **Two sequential stops** (today) | Rejected — the reported bug: fabricates an A→B travel leg and consumes two pin numbers, implying "A then B" when the truth is "A **or** B." |
| **Symmetric choice with an undecided state** (draft 1) | Rejected — the undecided state is the *sole* source of the hard parts: a read-model **collapse fold** inside the tested `legs`/`locatedSequenceNumbers`/weave, and an **"acknowledge uncertainty" routing gap**. Paying that to represent "we haven't decided" isn't earned; a live plan always has *something* penciled in. |
| **Primary + off-sequence backups** (draft 2) | Considered, near-miss — removes the undecided state (one column, `backupForStopID`), but is **asymmetric**: it imposes a canonical "real plan" the product doesn't need, and a *cycle* interaction has to rotate a star of pointers (re-point every sibling per press). The ring makes cycling a single flag flip and the members true peers. |
| **Two separate features — "alternatives" (a backup) vs "considerations" (a day menu)** | Rejected — identical structure (one slot, N candidates, one happens, no leg between); the only difference is *firmness/mood*, which the slot's schedule already carries. Two records + two UIs would encode a mood as a type and clutter the UI with a "which kind is this?" choice. One ring, presentation keyed off firmness (routed → current-pick + alternatives; loose → neutral menu). |
| **UI-only grouping** (view hides inactive members, model unchanged) | Rejected — `legs`/`allLegs` still zip the hidden member upstream of the view (AC #3 unmet) and directions pre-warm the phantom leg. The exclusion must live in the read-model. |
| **`AlternativeGroup` side-table** (like `TripStay`) | Rejected — a second synced record and a winner pointer that can dangle, for a relationship two loose columns on the members already express. |
| **A new `.alternative`/`.inactive` status** (vs. the `isActive` column) | Rejected — touches the ADR-0004 status lifecycle and every status switch; the column guard is one `&& isActive` clause per partition and leaves the enum alone (the ADR-0033 "no redundant case" lesson). |
| **Generalized branching graph** | Rejected — out of all proportion; the brief's explicit non-goal. |
| **`alternativeGroupID` + `isActive`, members share the slot, inactive off-sequence, cycle/disclosure (chosen)** | Leanest fit: two additive columns, **no changes to the tested leg/numbering core**, no undecided state, no collapse fold, O(1) cycle, co-equal peers, and the ring composes with the solver / reconciliation as a ready-made constraint fix. |

## Relationship to prior decisions

- **ADR-0006 (flat `TripIdea` columns):** two additive flat columns; SQLiteData additive-column,
  no migration friction, CloudKit-friendly.
- **ADR-0007 (single-FK / reconcile-on-read):** `alternativeGroupID` is a loose UUID reconciled on
  read like `ideaID`; a dissolved/raced ring degrades to an ordinary stop or a
  lowest-rank-active ring.
- **ADR-0010 (freeform stops):** a freeform stop can be a ring member — "picnic we packed" as an
  alternative to a restaurant — carrying the two columns like any `TripIdea`.
- **ADR-0033 (floating untimed stops):** the **active** member is an ordinary positioned stop and
  keeps all of ADR-0033 (`dayRank`, anchored interleave); inactive members share the slot but are
  off-sequence, so `effectiveIntraDaySort` only ever sees the active one. A **loose** slot's
  neutral menu (zero active) leans directly on ADR-0033's timing-neutral behavior — the app
  already navigates around untimed stops with no leg/ETA, so nothing new is needed to route
  around an undecided open block.
- **ADR-0029 (`StartDaySolver`) / M7 (calendar reconciliation):** the composition payoff — an
  inactive alternative is precisely *what you cycle to when the active stop fails a constraint* (a
  solver closed-day for the intended meal; a reservation that moves or vanishes under
  reconciliation). Those surfaces can suggest "active option unavailable → cycle to Gostner."
- **M3 travel legs / now-marker:** unchanged — they run over the day's active stops; inactive
  members are simply not among them.

## Consequences

- **GalavantSchema (pure, test-first):** two additive `TripIdea` columns; an `&& isActive` guard
  added to the three scheduled partitions (`scheduled` / `itinerary` / `toBeScheduled`); a new
  `alternatives(forStop:)` projection. **No changes to
  `legs`/`allLegs`/`locatedSequenceNumbers`/`framingCoordinates`/`itineraryItems`** — the
  correctness win (AC #3) is structural. Unit-tested in-memory (STYLE functional core): an
  inactive member never appears in a day/bucket/leg, cycling changes only which member routes, and
  an ungrouped trip is byte-identical to today.
- **Ops:** `addAlternative(_:to:)` / `cycleAlternative(_:)` / `setActiveAlternative(_:)` /
  `promoteAlternative(_:)` (the mirror of add — extract to a standalone stop) / `removeAlternative(_:)`,
  delete-active-promotes-next, one-member-remnant + no-active-member reconcile. Invariant: exactly
  one active on a routed slot, at most one on a loose slot.
- **App:** the disclosure ring row (routed: current-pick + alternatives; loose: a neutral menu)
  with cycle + **promote** controls in `TripItineraryView`; the muted-on-expand canvas pins;
  `StopMenu` "Add as alternative to…" / "Add alternative"; `swiftui-specialist` checkpoint; device
  install on the iPad Pro 13-inch (M5) sim ([[preferred-review-sim]]).
- **No CloudKit sync-registration change** — both columns ride `TripIdea`'s existing registration.
- **AC #7 (existing linear itineraries unchanged):** an ordinary stop is `alternativeGroupID ==
  nil`, `isActive == true` and takes every path exactly as today — the guard is a no-op, and the
  routed core is literally unmodified.

## Slices

- **Slice 1 — schema + active-only partition:** the two columns; the `&& isActive` guard on
  `scheduled` / `itinerary` / `toBeScheduled`; the `alternatives(forStop:)` projection; in-memory
  tests that an inactive member never appears in a day/bucket/leg, that cycling changes only which
  member routes, and that an ungrouped trip is byte-identical to today. **Suggested executor:
  Opus** — touches the read-model partition; wants the byte-identical guardrail proven.
- **Slice 2 — write ops:** `addAlternative` / `cycleAlternative` / `setActiveAlternative` /
  `promoteAlternative` (extract to a standalone stop) / `removeAlternative`, delete-active-promotes-next,
  and the remnant/no-active reconcile; unit-tested for the invariant (exactly-one-active on a
  routed slot, at-most-one on a loose one) and the multi-promote resolution. **Suggested executor:
  Sonnet** — a guarded ops slice on tested precedent.
- **Slice 3 — UI:** the itinerary **disclosure row** — a routed slot's current-pick + alternatives
  and a loose slot's neutral menu — with tap-to-activate, **promote**, add/remove, an inline
  **cycle** (⟳) control and "N of M" badge; the muted-on-expand canvas pins (no polyline);
  `StopMenu` contextual creation; built and installed on the iPad Pro 13-inch (M5) sim. **Suggested
  executor: Opus** — SwiftUI expandable-row + canvas work.
- **Slice 4 — docs:** flip to accepted; ROADMAP / trip-canvas / trip-time-model notes.

## Acceptance criteria (from the brief)

1. Two alternatives occupy one logical itinerary position — §1/§2 (the ring shares one slot and
   one pin number; only the active member sequences).
2. UI communicates A **or** B, not A then B — §5 (one active row with a disclosure to the ring +
   a cycle control; never a second sequential row).
3. No travel segment between alternatives — §2 (structural: inactive members are never in the
   routed sequence, so the zip cannot pair them).
4. Either alternative selectable later, incl. during the trip — §4 (cycle / set-active, anytime).
5. Selection determines the operational route — §3/§4 (the active member is always the routed
   stop; cycling swaps which member that is).
6. The rejected alternative stays recoverable/changeable — §4 (inactive members are retained in
   the ring; cycle back anytime).
7. Existing linear itineraries need no behavioral change — Consequences (the guard is a no-op on
   `alternativeGroupID == nil` / `isActive`; the routed core is unmodified).
