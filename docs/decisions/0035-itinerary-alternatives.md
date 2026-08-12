# ADR-0035: Itinerary backup plans — a primary stop with off-sequence fallbacks

*Status: proposed — 2026-08-12. **Reframed the same day** from a symmetric "choice" model
(two co-equal candidates, exactly one chosen, an undecided state before resolution) to an
**asymmetric primary + backup** after review: the undecided state was the sole source of the
hard parts — a read-model collapse fold inside the tested leg/numbering core, and an
"acknowledge uncertainty" routing gap. An always-present primary removes both. Extends
ADR-0010 (freeform stops) and ADR-0033 (floating untimed stops); rides ADR-0007 (single-FK /
reconcile-on-read) and ADR-0006 (flat `TripIdea` columns). Composes with ADR-0029
(`StartDaySolver`) and M7 (calendar reconciliation) — a backup is the ready-made fix when a
primary fails a constraint. Prompted by a real Dolomites plan: lunch at **Baita Sanon Hütte**
with **Gostner Schwaige** as the fallback — today only expressible as two sequential stops,
which fabricates a phantom travel leg between them.*

## Context

The itinerary is a **flat list of `TripIdea` rows** projected into a linear day. Two of those
projections are what make a day read as a line, and both are derived from **list adjacency**:

1. **Travel legs are zipped over consecutive located stops.** `TripPlan.legs(forDay:)`
   (GalavantSchema/TripPlan+Travel.swift:20) and the connector weave in
   `TripPlan.itineraryItems(forDay:)` (TripPlan.swift:416) do `zip(stops, stops.dropFirst())`
   over the day's located stops. Put Baita and Gostner adjacent in the list and the model
   **automatically emits a Baita→Gostner leg** with an ETA — the falsehood we must not print.

2. **Pin/sequence numbers are positional.** `TripPlan.locatedSequenceNumbers(forDay:)`
   (TripPlan.swift:312) numbers located stops by `enumerated()` position — two stops eat two
   numbers.

The product need is narrow: *some stops have a fallback* — "plan on Baita; if it's closed,
fully booked, or we're not feeling it, Gostner." The question is how to model the fallback so
it doesn't lie about the route.

**The key design decision (reframed):** an earlier draft modeled this as a *symmetric choice* —
two co-equal candidates sharing one slot, exactly one eventually chosen, **undecided** until
then. That undecided state is what forced the machinery: because both candidates sat *in* the
day sequence, every positional projection (`legs`, `locatedSequenceNumbers`, the weave) had to
be taught to **collapse** a group to one slot; and because "chosen" could be empty, routing
needed an "acknowledge uncertainty, omit the leg" branch. All of that is cost incurred to
represent *not having decided yet*.

Real trip planning rarely leaves a stop genuinely undecided — you usually have a **lean** and a
**fallback**. Modeling that asymmetry directly (a primary you plan around, a backup you hold in
reserve) removes the undecided state, and with it the collapse fold and the routing gap. The
day always has a concrete linear answer.

This is **not** a branching-itinerary graph, and it is distinct from **Ideas** (merely under
consideration, not on the itinerary) and **optional/skippable stops** (something dropped
entirely, with no "fall to this instead"). It solves exactly: *this stop has a fallback.*

## Decision

**A stop may carry one or more off-sequence backups. The primary is an ordinary sequenced
stop; a backup is attached data that never enters the day's route.** There is no undecided
state — the primary *is* the plan until a human promotes a backup.

### 1. One additive column: `TripIdea.backupForStopID: UUID?`

Per ADR-0006 (flat columns) and ADR-0007 (the one real FK is to `Trip`; everything else is a
loose, reconcile-on-read UUID):

```swift
public var backupForStopID: TripIdea.ID?   // nil = ordinary stop / primary; set = a backup for that stop
```

- **`nil`** — an ordinary stop. A *primary* is simply an ordinary stop that happens to have
  backups pointing at it; nothing marks it specially (the read-model finds its backups by the
  pointer).
- **set** — this row is a backup *for* the named stop. A loose UUID, not a SQL FK (like
  `ideaID`), reconciled on read. **N** backups may point at one primary (ordered by their
  existing `shortlistRank`/`dayRank`); V1's UI shows a short fallback list.
- **No "chosen" flag.** The primary is the plan by construction; there is nothing to resolve.
  This is the whole simplification — one column, no selection state, no invariant to enforce
  beyond "a backup points at a real primary."

Rides `TripIdea`'s existing CloudKit registration — **no sync-registration change**.

### 2. A backup is off-sequence — the tested linear core is untouched

A backup carries **no slot of its own** (its `dayNumber`/schedule is inert; it belongs to its
primary's position). It is excluded at the one partition boundary the read-model already has:

- `TripPlan.scheduled`, `TripIdea.itinerary`, and `TripIdea.toBeScheduled` each add
  `&& backupForStopID == nil` to their existing `status == .scheduled` filter. A backup never
  lands in a day, in the To-Be-Scheduled bucket, or the Ideas "Scheduled" section.
- A new projection `backups(forStop: TripIdea.ID) -> [ResolvedStop]` surfaces them, keyed by
  the primary's id.

**Because a backup is never in the day's stop list, `legs`, `locatedSequenceNumbers`,
`framingCoordinates`, and the `itineraryItems` weave never see it** — with *zero* changes to
any of them. The primary flows through every one exactly as an ordinary stop does today. There
is **no collapse fold**, and the phantom Baita→Gostner leg is **structurally impossible**: the
two were never adjacent in the routed sequence to begin with (AC #3, now met for free rather
than enforced).

### 3. Routing is always concrete — no uncertainty branch

The route always runs `prev → primary → next`. There is no undecided state, so there is no
"omit the leg / acknowledge uncertainty" case (the symmetric model's thorniest sub-case, gone).
`baseLegs` / lodging-to-first-stop routing is likewise unchanged — the primary is the first
stop as today.

### 4. Selecting a backup later = a swap write (works mid-trip)

Promotion is a single tested op, not a read-model resolution:

- `promoteBackup(_:)` — the chosen backup takes the primary's slot (copy `dayNumber` /
  `schedule` / `dayRank`), the **old primary becomes a backup of it**, and any sibling backups
  re-point to the new primary. The demoted primary is **retained** (AC #6); re-promoting flips
  it back. Runnable during the trip (AC #4, #5 — the route follows because the new primary is
  now the sequenced stop).

### 5. UI: a fallback attached to its primary — never a second row

- **Timeline (`TripItineraryView`):** the primary renders as an ordinary numbered stop; a
  compact **"Backup: <name>"** affordance sits under it (tap → promote / edit / remove). No
  second sequential row, no connector row between them.
- **Canvas:** the primary wears its ordinary numbered pin; a backup draws **only when its
  primary is selected**, as a muted, unnumbered pin, contributing **no** polyline segment
  (AC #2, #3).
- **Creation is contextual** (no abstract group to build): **"Add as backup to…"** on a
  shortlisted idea, or **"Add backup"** on a stop, in `StopMenu` (Galavant/Trips/StopMenu.swift)
  — it just sets the pointer.

### 6. Deletion & orphans

- Deleting a **primary** promotes its top-ranked backup in the same write, so the plan
  survives; with no backup it deletes normally. Deleting a **backup** just removes it.
- A backup **orphaned** by a cross-device primary delete (its `backupForStopID` points at a
  gone/non-scheduled stop) reconciles on read to an ordinary **unscheduled** stop — it surfaces
  in To-Be-Scheduled, **recoverable, never silently dropped** — the same reconcile discipline
  `resolve(_:)` applies to a deleted `ideaID` (TripPlan.swift:128).

### 7. What we explicitly do **not** build

No symmetric undecided "choose one" state (§Why not); no branching/convergence; no
optional/skippable concept; no cross-alternative optimization. The Ideas pool stays the home
for "maybe someday" — a backup is a *scheduled fallback* for a specific slot.

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **Two sequential stops** (today) | Rejected — the reported bug: fabricates an A→B travel leg and consumes two pin numbers, implying "A then B" when the truth is "A, or else B." |
| **Symmetric choice: two co-equal candidates, exactly one chosen, undecided until then** (this ADR's first draft) | Rejected for V1 — the undecided state is the *only* thing that forces both hard parts: a read-model **collapse fold** inside the tested `legs`/`locatedSequenceNumbers`/weave (both candidates sit in-sequence and must be squashed to one slot), and an **"acknowledge uncertainty" routing gap** (chosen may be empty). Real planning almost always has a lean + a fallback; paying that cost to model "we haven't decided" isn't earned. Kept available if genuinely-undecided stops prove common. |
| **UI-only attachment** (view hides the second stop, model unchanged) | Rejected — `legs`/`allLegs` still zip A→B upstream of the view (AC #3 unmet) and directions pre-warm the phantom leg. The backup must be excluded in the read-model. |
| **`AlternativeGroup` / backup side-table** (like `TripStay`) | Rejected — heavier: a second synced record and a pointer that can dangle, for a relationship that a single loose column on the backup already expresses. |
| **A new `.backup` status** (vs. the `backupForStopID` column) | Rejected — touches the ADR-0004 status lifecycle and every status switch; the column guard is one `&& backupForStopID == nil` clause per partition and leaves the enum alone (the ADR-0033 "no redundant case" lesson). |
| **Generalized branching graph** | Rejected — out of all proportion; the brief's explicit non-goal. |
| **One loose `backupForStopID` column, backups off-sequence, promote-by-swap (chosen)** | Leanest fit: one additive column, **no changes to the tested leg/numbering core** (backups filter out before it), no undecided state, no collapse fold, and the fallback composes with the solver / reconciliation as a ready-made constraint fix. |

## Relationship to prior decisions

- **ADR-0006 (flat `TripIdea` columns):** one additive flat column; SQLiteData additive-column,
  no migration friction, CloudKit-friendly.
- **ADR-0007 (single-FK / reconcile-on-read):** `backupForStopID` is a loose UUID reconciled on
  read like `ideaID`; a dangling backup degrades to an ordinary unscheduled stop.
- **ADR-0010 (freeform stops):** a freeform stop can be a primary *or* a backup — "picnic we
  packed" as the fallback to a restaurant — carrying `backupForStopID` like any `TripIdea`.
- **ADR-0033 (floating untimed stops):** the **primary** is an ordinary positioned stop and
  keeps all of ADR-0033 (`dayRank`, anchored interleave) unchanged; a **backup** is off-sequence
  and carries no `dayRank` role, so `effectiveIntraDaySort` never sees it.
- **ADR-0029 (`StartDaySolver`) / M7 (calendar reconciliation):** the composition payoff — a
  backup is precisely *what you fall to when the primary fails a constraint* (a solver closed-day
  for the intended meal; a reservation that moves or vanishes under reconciliation). Those
  surfaces can point a "primary unavailable → promote backup" fix at an existing fallback. This
  hook exists only because the model is asymmetric.
- **M3 travel legs / now-marker:** unchanged — they run over the day's ordinary stops; a backup
  is simply not among them.

## Consequences

- **GalavantSchema (pure, test-first):** one additive `TripIdea.backupForStopID` column; a
  `backupForStopID == nil` guard added to the three scheduled partitions
  (`scheduled` / `itinerary` / `toBeScheduled`); a new `backups(forStop:)` projection. **No
  changes to `legs`/`allLegs`/`locatedSequenceNumbers`/`framingCoordinates`/`itineraryItems`** —
  the correctness win (AC #3) is structural. All unit-tested in-memory (STYLE functional core):
  a backup never appears in a day/bucket, never produces a leg, and an ungrouped trip is
  byte-identical to today.
- **Ops:** `addBackup(_:to:)` / `promoteBackup(_:)` (the slot swap) / `removeBackup(_:)`, plus
  delete-primary-promotes-backup and the orphan reconcile. No selection invariant to police.
- **App:** the attached "Backup: …" affordance in `TripItineraryView`; the muted-on-selection
  canvas pin; `StopMenu` "Add as backup to…" / "Add backup"; `swiftui-specialist` checkpoint;
  device install on the iPad Pro 13-inch (M5) sim ([[preferred-review-sim]]).
- **No CloudKit sync-registration change** — the column rides `TripIdea`'s existing registration.
- **AC #7 (existing linear itineraries unchanged):** a stop with `backupForStopID == nil` takes
  every path exactly as today — the guard is a no-op on ordinary stops, and the routed core is
  literally unmodified.

## Slices

- **Slice 1 — schema + off-sequence partition:** the column; the `backupForStopID == nil` guard
  on `scheduled` / `itinerary` / `toBeScheduled`; the `backups(forStop:)` projection; in-memory
  tests that a backup never appears in a day, the bucket, or a leg, and that an ungrouped trip is
  byte-identical to today. **Suggested executor: Opus** — small, but it touches the read-model
  partition and wants the "byte-identical" guardrail proven.
- **Slice 2 — write ops:** `addBackup` / `promoteBackup` (slot swap) / `removeBackup`,
  delete-primary-promotes-backup, and the orphan→To-Be-Scheduled reconcile; unit-tested.
  **Suggested executor: Sonnet** — a guarded ops slice on tested precedent; the swap + reconcile
  are the only judgment, covered by tests.
- **Slice 3 — UI:** the attached "Backup: …" timeline affordance + promote/edit/remove; the
  muted-on-selection canvas pin (no polyline); `StopMenu` contextual creation; built and
  installed on the iPad Pro 13-inch (M5) sim. **Suggested executor: Opus** — SwiftUI row/canvas
  work.
- **Slice 4 — docs:** flip to accepted; ROADMAP / trip-canvas / trip-time-model notes.

## Acceptance criteria (from the brief)

1. Two alternatives occupy one logical itinerary position — §2 (the primary holds the slot and
   its number; the backup is attached to it, not a second position).
2. UI communicates A **or** B, not A then B — §5 (backup shown as a fallback under its primary /
   a muted pin, never a second sequential row).
3. No travel segment between alternatives — §2 (structural: the backup is never in the routed
   sequence, so the zip cannot pair them).
4. Either alternative selectable later, incl. during the trip — §4 (`promoteBackup` swap, anytime).
5. Selection determines the operational route — §3/§4 (the primary is always the routed stop;
   promotion swaps which stop that is).
6. The rejected alternative stays recoverable/changeable — §4 (the demoted primary is retained
   as a backup; re-promote flips it).
7. Existing linear itineraries need no behavioral change — Consequences (the guard is a no-op on
   `backupForStopID == nil`; the routed core is unmodified).
