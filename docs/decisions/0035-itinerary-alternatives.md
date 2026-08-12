# ADR-0035: Itinerary alternatives — one itinerary position holds "A or B," exactly one chosen

*Status: proposed — 2026-08-12. Extends ADR-0010 (freeform stops), ADR-0033 (floating untimed
stops), and the M3 travel-leg timeline. Rides the ADR-0007 single-FK / reconcile-on-read pattern
and ADR-0006 flat `TripIdea` columns — no new table. Prompted by a real Dolomites plan: lunch at
**Baita Sanon Hütte OR Gostner Schwaige** — two candidates for one lunch slot that today can only
be modeled as two sequential stops, which fabricates a travel leg between them.*

## Context

The itinerary is a **flat list of `TripIdea` rows** projected into a linear day. Two of those
projections are what make a day read as a line, and both are derived from **list adjacency**, not
from any stored structure — so representing "A or B" as two rows breaks them:

1. **Travel legs are zipped over consecutive located stops.** `TripPlan.legs(forDay:)`
   (GalavantSchema/TripPlan+Travel.swift:20) and the connector weave in
   `TripPlan.itineraryItems(forDay:)` (TripPlan.swift:416) do `zip(stops, stops.dropFirst())` over
   the day's located stops. Put Baita and Gostner adjacent in the list and the model **automatically
   emits a Baita→Gostner leg** with an ETA — the exact falsehood we must not print. This is upstream
   of the view; no UI treatment can suppress it.

2. **Pin/sequence numbers are positional.** `TripPlan.locatedSequenceNumbers(forDay:)`
   (TripPlan.swift:312) numbers located stops by `enumerated()` position. Two alternatives eat two
   numbers (3 *then* 4) instead of sharing one slot.

Everything else that reads the itinerary — `itinerary`, `scheduled`, framing
(`framingCoordinates`), the now-marker weave, the intra-day sort (`effectiveIntraDaySort`, ADR-0033)
— also assumes **one row = one position**. There is no grouping concept between `TripIdea` rows
today; `TripStay` (ADR-0011) and `TripDayRegion` (ADR-0012) are separate side-tables keyed by a loose
UUID, not groupings *of* stops.

This is not a new subsystem, and it is emphatically **not** a branching-itinerary graph. The product
need is narrow: **one itinerary position may contain two or more candidate stops, exactly one of
which is expected to be chosen.** The day stays linear. What's missing is a way to tell the read-model
that a set of existing stops **collapse into a single slot** for ordering, numbering, and — the
correctness core — leg generation.

Alternatives are also a **distinct concept** from the neighbours it could be confused with, and the
schema should keep them distinct: **Ideas** (merely under consideration, not on the itinerary),
**optional stops** (something we may skip *entirely* — no "instead-of" pairing), and general
**conditional/branching** itineraries (arbitrary branches and convergence). This ADR solves only
"we will do exactly one of these."

## Decision

**An alternatives group is a set of existing `TripIdea` stops that share one itinerary position,
with at most one member marked chosen.** Unresolved = no member chosen (an open "choose one");
resolved = exactly one chosen. It preserves the linear day: the group occupies a single slot, and no
travel leg is ever created *between* its members.

### 1. Two additive flat columns on `TripIdea` — no new table

Per ADR-0006 (flat columns) and ADR-0007 (single real FK is to `Trip`; everything else is a loose,
reconcile-on-read UUID):

```swift
public var alternativeGroupID: UUID?   // nil = ordinary stop; shared by a group's members
public var isChosenAlternative = false // the selected member; unresolved = none true
```

- **`alternativeGroupID`** is a loose UUID, *not* a SQL FK — exactly like `ideaID`. It is minted
  when a group forms and shared by its members. There is **no `AlternativeGroup` row**: the group is
  *defined by* the set of members carrying the same id, and its "unresolved vs selected" state is the
  fold of the members' `isChosenAlternative` flags. A one-member remnant (the other alternative
  deleted) reconciles on read back to an ordinary stop — the same orphan-drop discipline
  `resolve(_:)` already applies to a deleted `ideaID` (TripPlan.swift:128).
- **`isChosenAlternative`** carries selection. Invariant enforced by the write op, not the schema:
  at most one member of a group is true. Storing selection as a per-member flag (rather than a
  "winner id" on a group row) is the sync-safest shape — each member's selection rides its own
  `TripIdea` CloudKit record; there is no separate row to keep consistent, and a lost update
  degrades to "no winner" (unresolved), never to a dangling pointer.

Both columns ride `TripIdea`'s existing CloudKit registration — **no sync-registration change**
(cf. ADR-0033's `dayRank`).

### 2. The members share one slot — a grouped read-model unit

Members of a group **share the slot's placement**: they carry the same `dayNumber` and the same
intra-day position (`schedule` band + `dayRank`, ADR-0033), so they sort as a unit and never
straddle other stops. The read-model gains a grouping fold that the day projections run **before**
numbering and leg generation:

- **Sequence numbers:** a group consumes **one** slot number. Its located members share that number
  (rendered e.g. "4 · choose one", both map pins wearing 4). `locatedSequenceNumbers(forDay:)` counts
  a group once.
- **Ordering:** `orderedDayStops` / `effectiveIntraDaySort` treat the group as a single ordered unit
  keyed by the shared slot.
- **Framing:** unchanged — `framingCoordinates` already folds *all* located stops, so both candidates
  stay in frame for free.

A new `ItineraryItem` case carries the group to the view:

```swift
case choice(ResolvedChoice)   // ≥2 candidate ResolvedStops sharing one slot; optional chosen member
```

where the ordinary `.stop` case is still what a **resolved** group renders through downstream
(routing/now-marker) once a member is chosen — see §3.

### 3. Legs: collapse each group to its chosen member; never A→B (the correctness core)

Before the `zip`, every day projection **collapses each alternatives group to a single representative
stop**:

- **Resolved group** → its `isChosenAlternative` member. Routing is `prev → chosen → next`, exactly
  as if the chosen candidate were an ordinary stop. This is the operational route (AC #5).
- **Unresolved group** → **no representative; the leg is omitted.** We do *not* fabricate a single
  linear route through an undecided choice, and — the hard invariant (AC #3) — we **never** emit a
  member-to-member leg. `prev → (open choice) → next` shows the choice as a gap in the ETA chain, an
  honest acknowledgement of uncertainty rather than a made-up number. (A future refinement could
  route through a *nominated primary* candidate for continuity; V1 omits, as the least-wrong and
  smallest option.)

Concretely, `legs(forDay:)`, `allLegs`, and the connector weave in `itineraryItems(forDay:)` run over
the **collapsed** stop list, so a group's non-chosen members simply are not in the sequence the zip
walks. `baseLegs` / lodging-to-first-stop routing (TripPlan+Travel.swift:35) target the chosen member
(or, unresolved, skip to the next ordinary stop) the same way.

### 4. Timeline & canvas: "choose one," both pins, no line between

- **Timeline (`TripItineraryView`):** the `.choice` case renders a **"Choose one"** container — the
  candidate rows grouped under one slot number, each with a select affordance; the chosen member
  reads as active, the others as recoverable alternatives (AC #2, #6). No connector row is drawn
  between candidates.
- **Canvas:** **both** located candidates draw pins (sharing the slot number); **no polyline segment**
  connects them. The polyline routes through the collapsed representative — the chosen member, or a
  break at an unresolved group. Selection can happen from either surface, in planning **or during the
  trip** (AC #4).

### 5. Creation is contextual — no "make a group first"

Users never construct an abstract group. Grouping happens **behind the scenes** from a contextual
action on an existing stop, in `StopMenu` (Galavant/Trips/StopMenu.swift):

- **"Add as alternative to…"** on a shortlisted/candidate idea → pulls it and joins the target stop's
  slot, minting `alternativeGroupID` on both if the target wasn't already a group.
- **"Add alternative"** from an existing itinerary stop → opens the add-stop path pre-bound to that
  slot.

Leaving a group (choosing one and dismissing the rest, or deleting a candidate) reconciles a
one-member remnant back to an ordinary stop (§1).

### 6. What we explicitly do **not** build

No generalized branches or convergence; no nested choices; no "optional/skippable" stop concept; no
cross-alternative route optimization. `Idea`-level "considering" (the pool) stays the home for "maybe
someday" — an alternatives group is strictly *scheduled* stops competing for one slot. Those can be
revisited separately if a real use case demands them.

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **Two sequential stops** (today) | Rejected — the reported bug: fabricates an A→B travel leg and consumes two slot numbers, implying "A then B" when the truth is "A or B." |
| **UI-only grouping** (view collapses adjacent rows, model unchanged) | Rejected — `legs(forDay:)`/`allLegs` still zip A→B upstream of the view (AC #3 unmet), and pre-warmed directions would request the phantom leg. The grouping must live in the pure read-model. |
| **`AlternativeGroup` side-table** (like `TripStay`) holding group id + winner id + slot | Rejected for V1 — heavier: a second synced record per group to keep consistent, and a winner-id pointer that can dangle. The group needs no state beyond membership + selection, both of which live on the members. Revisit only if a group grows its own attributes. |
| **A new `Schedule`/status enum case for "choice"** | Rejected — a group is a *relationship among stops*, not a placement of one stop; the members keep their ordinary `.scheduled` status and shared slot. A new case would force every switch to handle a redundant state (the ADR-0033 lesson). |
| **Generalized branching graph** (arbitrary branches + convergence) | Rejected — out of all proportion to the need; the brief's explicit non-goal. Keeps the day linear. |
| **Two loose columns on `TripIdea` + collapse-to-representative in the read-model (chosen)** | Leanest fit: two additive columns (no migration friction, no sync-registration change), reuses the orphan-reconcile discipline, and turns AC #3 into a pure-function assertion over the collapsed day. |

## Relationship to prior decisions

- **ADR-0006 (flat `TripIdea` columns):** two additive flat columns; SQLiteData additive-column, no
  migration friction, CloudKit-friendly.
- **ADR-0007 (single-FK / reconcile-on-read):** `alternativeGroupID` is a loose UUID reconciled on
  read exactly like `ideaID`; a one-member remnant drops back to an ordinary stop, as an orphaned
  `ideaID` drops in `resolve(_:)`.
- **ADR-0010 (freeform stops):** a freeform stop can be an alternative — "picnic we packed" vs. a
  restaurant — with no extra work; it carries the grouping columns like any `TripIdea`.
- **ADR-0033 (floating untimed stops):** members share the slot's `dayNumber`, band, and `dayRank`,
  so `effectiveIntraDaySort` seats the whole group as one unit; the collapse runs before that sort's
  consumers. An Anytime choice is legal.
- **M3 travel legs / now-marker:** the leg generators run over the collapsed day; an unresolved group
  is timing-neutral (no leg, no lateness), the same posture ADR-0033 gives an untimed stop.
- **ADR-0011 (accommodations) / ADR-0012 (day region):** unaffected — stays and regions are
  slot-independent; `baseLegs` routes lodging → the collapsed first stop.

## Consequences

- **GalavantSchema (pure, test-first):** two additive `TripIdea` columns; a grouping fold
  (`ResolvedChoice` + a collapse helper) applied in `itinerary`/`scheduled`, `locatedStops` /
  `locatedSequenceNumbers`, `legs`/`allLegs`, and the `itineraryItems` weave; a new `ItineraryItem`
  case. All unit-tested in-memory (STYLE functional core) — **AC #3 ("no A→B leg") is a direct
  pure-function assertion** over a two-candidate day, which makes this a low-risk, test-first build.
- **Ops:** `addAlternative(to:)` / `chooseAlternative(_:)` / `removeAlternative(_:)` writing the two
  columns and enforcing the at-most-one-chosen invariant; group-aware delete (removing a member, and
  the one-member-remnant reconcile). Reuses existing tested write paths otherwise.
- **App:** the `.choice` "Choose one" container in `TripItineraryView`; both-pin / no-segment canvas
  treatment; `StopMenu` "Add as alternative to…" / "Add alternative"; `swiftui-specialist`
  checkpoint; device install on the iPad Pro 13-inch (M5) sim ([[preferred-review-sim]]).
- **No CloudKit sync-registration change** — both columns ride `TripIdea`'s existing registration.
- **AC #7 (existing linear itineraries unchanged):** a stop with `alternativeGroupID == nil` takes
  every path exactly as today — the collapse is a no-op on ungrouped stops.

## Slices

- **Slice 1 — schema + grouped read-model:** the two columns; `ResolvedChoice` + the collapse fold in
  `itinerary`/`scheduled` and `locatedSequenceNumbers`; in-memory tests that two members share one
  slot number and that an ungrouped day is byte-identical to today.
- **Slice 2 — legs (the correctness core):** collapse-to-representative in `legs`/`allLegs`/`baseLegs`
  and the `itineraryItems` weave; table-driven tests: unresolved group emits **no** member-to-member
  leg and no phantom prev→member ETA; resolved group routes `prev → chosen → next`; `prev → (open) →
  next` shows the expected gap.
- **Slice 3 — write ops:** `addAlternative` / `chooseAlternative` / `removeAlternative` + the
  at-most-one-chosen and one-member-remnant reconcile, unit-tested.
- **Slice 4 — UI:** the `.choice` "Choose one" timeline container + selection; canvas both-pins /
  no-segment; `StopMenu` contextual creation; built and installed on the iPad Pro 13-inch (M5) sim.
- **Slice 5 — docs:** flip to accepted; ROADMAP / trip-canvas / trip-time-model notes.

## Acceptance criteria (from the brief)

1. Two alternatives occupy one logical itinerary position — §2 (shared slot, one sequence number).
2. UI communicates A **or** B, not A then B — §4 ("Choose one" container; both pins, no line).
3. No travel segment between alternatives — §3 (collapse before the zip; the pure-function assertion).
4. Either alternative selectable later, incl. during the trip — §1/§4 (per-member flag; select from
   timeline or canvas anytime).
5. Selection determines the operational route — §3 (resolved group collapses to the chosen member).
6. The rejected alternative stays recoverable/changeable — §1 (a non-chosen member is retained, not
   deleted; re-choose flips the flag).
7. Existing linear itineraries need no behavioral change — Consequences (collapse is a no-op on
   `alternativeGroupID == nil`).
