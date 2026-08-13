# ADR-0035: Itinerary alternatives — a ring of stops sharing one slot, exactly one active

*Status: accepted — Slices 1 (schema + active-only partition), 2 (write ops), and 3 (UI) landed
and unit-tested; package/app verified (iPad Pro 13-inch M5 simulator, `BUILD SUCCEEDED`). Slice 3
added two presentation refinements beyond the original §5 sketch: a loose/Anytime slot's collapsed
row surfaces its effective-active member **by name** (`"<pick> · N options"`) rather than a generic
"open block" label, and the disclosure marks the current pick in both moods — the neutral-loose
styling of the draft proved unhelpful when collapsed, since every ring always has one effective
active member anyway. The cycle/badge controls moved to their own row under the title (in the
trailing cluster they collided with the schedule label). On-device dogfooding continues; further
tweaks are follow-ups, not accept-gates. **Twice-reframed the same day.**
Draft 1 was a symmetric
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
firm/timed slot shows a **current pick + alternatives**, while a loose/Anytime or unplaced slot
may render its peers **neutrally**, with no visual emphasis on the stored winner. This is a
presentation difference only: **every ring still has exactly one effective active member**. In
the living route model, any scheduled stop with a `dayNumber` — including `.day(n)` Anytime — is
part of the day's adjacency and can produce travel legs; only a day-less To-Be-Scheduled stop is
not yet in a day route. The user never declares "backup" vs "consideration"; splitting these into
two features would encode a mood as a type and clutter the UI with a "which kind?" choice.

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
- **`isActive`** records the intended winner. Normal writes leave **exactly one** member true in
  every ring, regardless of schedule firmness. A loose presentation may hide that emphasis; it
  does not create a zero-active domain state.
- **Members share the slot.** Every member of a ring carries the same `status` while grouped,
  schedule columns (`dayNumber`, `dayPart`, `startTime`, `endTime`), and `dayRank` (ADR-0033) —
  they occupy one position. Slot mutations made through the itinerary therefore **propagate to
  every live member in the ring in the same transaction** — including `dayRank`, so the shared-slot
  writer re-derives one canonical intra-day position for the whole ring and a raced divergence
  self-heals. Lifecycle actions never leave grouped inactive members in another pile, and they come
  in two shapes (§6): pulling the **whole slot** back to the shortlist (`unschedule`) dissolves the
  entire ring; a **per-member terminal** (`markDone` / `markSkipped`) extracts only that member and
  leaves the remaining peers a scheduled ring-minus-one.
  Content and commitment facts remain member-specific: `ideaID` / freeform text, `pinnedDate`,
  confirmation / booking URL / party size, and Calendar binding/time authority do not propagate.
  Cycling can therefore surface the newly active member's own booking fact. Cycling itself only
  changes activity flags. Order within the ring is the stable total order
  `(shortlistRank, id.uuidString)`, so devices agree even when ranks tie.

Both columns ride `TripIdea`'s existing CloudKit registration — **no sync-registration change**.

### 2. Inactive members are off-sequence — the tested linear core is untouched

The read-model computes one **effective active** member for each group, then keeps only that
member at the existing partition boundary:

- `TripPlan.scheduled`, `TripIdea.itinerary`, and `TripIdea.toBeScheduled` filter to the effective
  winner. An inactive member never lands in a day, the To-Be-Scheduled bucket, or the Ideas
  "Scheduled" section.
- A new projection `alternatives(forStop: TripIdea.ID) -> [ResolvedStop]` returns a stop's ring
  in canonical ring order for the disclosure UI; presentation derives the active index separately.

The stored flags can temporarily contain zero or several active members after concurrent offline
writes. That must never make a slot disappear or duplicate itself: choose the effective winner
deterministically — the first stored-active member in canonical order, or the first member in
canonical order when none is stored active. This is a pure, non-mutating read reconciliation.
The next operation over that ring canonicalizes storage back to one true flag. Thus every device
shows the same winner before cleanup, and no ordinary read silently rewrites synced state.

**Because inactive members are never in the day's stop list, `legs`, `locatedSequenceNumbers`,
`framingCoordinates`, and the `itineraryItems` weave never see them** — with *zero* changes to
any of them. The active member flows through every one exactly as an ordinary stop does today.
There is **no collapse fold**, and the phantom Baita→Gostner leg is **structurally impossible**:
the two are never both in the routed sequence (AC #3, met for free rather than enforced).

### 3. Routing is always concrete — no uncertainty branch

A scheduled slot with a `dayNumber` routes `prev → effective active → next`. This includes a bare
`.day(n)` **Anytime** stop: Anytime is timing-neutral for now-marker/conflict calculations, but it
is geographically sequenced by `dayRank` and participates in `legs(forDay:)`. Only a scheduled
stop with no `dayNumber` (the To-Be-Scheduled bucket) is absent from a day route. Because every
ring always has one effective active member, there is no "omit the leg / acknowledge uncertainty"
branch. `baseLegs` and lodging routing remain unchanged.

### 4. Cycle / set-active — a flag flip, works mid-trip

Selection is a single tested op, not a read-model resolution, and — because members share the
slot — it **never copies slot columns**:

- `cycleAlternative(_:)` — advance `isActive` from the effective winner to the **next in the
  canonical ring order**, wrapping. The quick "just show me the other one" gesture.
- `setActiveAlternative(_:)` — make a **specific** member active (the disclosure's tap-to-choose).
- `promoteAlternative(_:)` — the **mirror of `addAlternative`**: pull a member **out** of the ring
  into its own standalone, routed stop (clear its `alternativeGroupID`, place it at its own
  position on the day). Because add/remove already exist, promote is the same machinery run
  backwards; and a ring left with one member reconciles to an ordinary stop (§6), so promoting
  naturally dissolves the ring once you've decided.

Selection writes canonicalize the whole ring to exactly one stored active flag. They do not copy
slot columns; those are already shared and change only through the propagation rule in §1. The
routing, ETAs, pin position, and start-day/reconciliation checks all recompute downstream because
the active member's coordinates changed — **no preview is computed or needed** (the user cycles
and sees the real re-routed day). Runnable during the trip (AC #4, #5). **Promote is what lets a
neutral menu resolve gracefully:** you needn't pick one and lose the rest — do one in the moment
(`setActive`), or promote one **or several** into the real plan and drop the others ("we'll do
the market *and* the castle"). A promoted stop lands on the same day beside its old slot and is
scheduled like any stop.

### 5. UI: one active row, a disclosure to the ring, a cycle control

- **Timeline (`TripItineraryView`):** every slot renders as its **effective-active** member —
  an ordinary numbered row named for the current pick. A firm/timed slot shows that name plainly;
  a **loose**/Anytime slot appends **`· N options`** (e.g. "Baita Sanon Hütte · 2 options") rather
  than a generic "open block" label — the draft's neutral rendering proved unhelpful when collapsed,
  and every ring always has one effective active member to name. The **cycle** (⟳) control and
  **"N of M"** badge + **disclosure arrow** sit on their **own row under the title** (in the row's
  trailing cluster they collided with the schedule label and the badge wrapped). Expanding reveals
  the ring with the **current pick marked in both moods**, where you tap to make one active
  (`setActiveAlternative`), **promote** one into the itinerary (`promoteAlternative`), or **add /
  remove** options. It is never a second *sequential* row — the ring lives inside one slot.
- **Canvas:** the active member wears its ordinary numbered pin; the inactive alternatives draw
  **only while the row's disclosure is expanded (or the stop is selected)**, as muted, unnumbered
  pins, contributing **no** polyline segment (AC #2, #3).
- **Creation is contextual:** **"Add as alternative to…"** on a shortlisted idea, or **"Add
  alternative"** on a stop, in `StopMenu` (Galavant/Trips/StopMenu.swift) — it mints/joins the
  `alternativeGroupID` and copies the slot onto the new member (inactive).

### 6. Deletion, terminals & orphans

- **Delete** is the general dissolver: deleting the **active** member makes the next member in the
  ring active in the same write, so the slot survives; deleting an **inactive** member just removes
  it. There is no separate `removeAlternative` op — `remove(stopID:)` deletes the row and then
  re-normalizes whatever peers remain, so a ring reduced to **one** member reconciles back to an
  ordinary stop (clear `alternativeGroupID`).
- **Per-member terminals** (`markDone`, `markSkipped`) extract exactly the marked member — it keeps
  its placement as history but leaves the ring (`alternativeGroupID` cleared) — and the **remaining
  peers stay a scheduled ring-minus-one**, with a fresh effective active reconciled deterministically.
  This is symmetric between done and skipped, and it holds whichever member is marked: marking an
  *inactive* peer done never empties the active slot. (`markDone` additionally flips the pool idea's
  `visited` per ADR-0004.) Pulling the **whole slot** back with `unschedule` is the only lifecycle
  action that dissolves the entire ring at once, returning every peer to a contiguous shortlist.
- A member **orphaned** by a cross-device group dissolution (its `alternativeGroupID` names only
  one live member) degrades to an ordinary stop. A race that leaves zero or several stored-active
  members uses the effective-winner rule in §2 — **recoverable, never silently dropped or
  duplicated**. The next explicit ring write repairs the stored flags/remnant. A structurally
  corrupt row (neither `ideaID` nor inline title) is dropped from every projection and reported
  once when the read-model is built, not on each projection.

### 7. What we explicitly do **not** build

No undecided state on any slot (every ring has an effective answer — §Why not); no
branching/convergence; no optional/skippable concept; no cross-alternative route optimization; no
routing *preview* (you cycle and see the real day). A loose slot's neutral styling is not an
undecided domain state. The Ideas pool stays the home for "maybe someday" — a ring member is a
*scheduled* option for a specific slot.

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **Two sequential stops** (today) | Rejected — the reported bug: fabricates an A→B travel leg and consumes two pin numbers, implying "A then B" when the truth is "A **or** B." |
| **Symmetric choice with an undecided state** (draft 1) | Rejected — the undecided state is the *sole* source of the hard parts: a read-model **collapse fold** inside the tested `legs`/`locatedSequenceNumbers`/weave, and an **"acknowledge uncertainty" routing gap**. Paying that to represent "we haven't decided" isn't earned; a live plan always has *something* penciled in. |
| **Primary + off-sequence backups** (draft 2) | Considered, near-miss — removes the undecided state (one column, `backupForStopID`), but is **asymmetric**: it imposes a canonical "real plan" the product doesn't need, and a *cycle* interaction has to rotate a star of pointers (re-point every sibling per press). The ring makes cycling a single flag flip and the members true peers. |
| **Two separate features — "alternatives" (a backup) vs "considerations" (a day menu)** | Rejected — identical structure (one slot, N candidates, one happens, no leg between); the only difference is *firmness/mood*, which the slot's schedule already carries. Two records + two UIs would encode a mood as a type and clutter the UI with a "which kind is this?" choice. One ring, presentation keyed off firmness (firm → current-pick + alternatives; loose → neutral peers), while both retain one effective active. |
| **UI-only grouping** (view hides inactive members, model unchanged) | Rejected — `legs`/`allLegs` still zip the hidden member upstream of the view (AC #3 unmet) and directions pre-warm the phantom leg. The exclusion must live in the read-model. |
| **`AlternativeGroup` side-table** (like `TripStay`) | Rejected — a second synced record and a winner pointer that can dangle, for a relationship two loose columns on the members already express. |
| **A new `.alternative`/`.inactive` status** (vs. the `isActive` column) | Rejected — touches the ADR-0004 status lifecycle and every status switch; the column guard is one `&& isActive` clause per partition and leaves the enum alone (the ADR-0033 "no redundant case" lesson). |
| **Generalized branching graph** | Rejected — out of all proportion; the brief's explicit non-goal. |
| **`alternativeGroupID` + `isActive`, members share the slot, inactive off-sequence, cycle/disclosure (chosen)** | Leanest fit: two additive columns, **no changes to the tested leg/numbering core**, no undecided state, no collapse fold, O(1) cycle, co-equal peers, and the ring composes with the solver / reconciliation as a ready-made constraint fix. |

## Relationship to prior decisions

- **ADR-0006 (flat `TripIdea` columns):** two additive flat columns; SQLiteData additive-column,
  no migration friction, CloudKit-friendly.
- **ADR-0007 (single-FK / reconcile-on-read):** `alternativeGroupID` is a loose UUID reconciled on
  read like `ideaID`; a dissolved/raced ring degrades to an ordinary stop or a deterministically
  selected effective-active ring.
- **ADR-0010 (freeform stops):** a freeform stop can be a ring member — "picnic we packed" as an
  alternative to a restaurant — carrying the two columns like any `TripIdea`.
- **ADR-0033 (floating untimed stops):** the **active** member is an ordinary positioned stop and
  keeps all of ADR-0033 (`dayRank`, anchored interleave); inactive members share the slot but are
  off-sequence, so `effectiveIntraDaySort` only ever sees the effective active one. A loose
  `.day(n)` slot may render neutrally, but its active member still occupies that geographic
  position and participates in the day's travel adjacency.
- **ADR-0029 (`StartDaySolver`) / M7 (calendar reconciliation):** the composition payoff — an
  inactive alternative is precisely *what you cycle to when the active stop fails a constraint* (a
  solver closed-day for the intended meal; a reservation that moves or vanishes under
  reconciliation). Those surfaces can suggest "active option unavailable → cycle to Gostner."
- **M3 travel legs / now-marker:** unchanged — they run over the day's active stops; inactive
  members are simply not among them.

## Consequences

- **GalavantSchema (pure, test-first):** two additive `TripIdea` columns; effective-active
  filtering at the three scheduled partitions (`scheduled` / `itinerary` / `toBeScheduled`); a
  new `alternatives(forStop:)` projection. **No changes to
  `legs`/`allLegs`/`locatedSequenceNumbers`/`framingCoordinates`/`itineraryItems`** — the
  correctness win (AC #3) is structural. Unit-tested in-memory (STYLE functional core): an
  inactive member never appears in a day/bucket/leg, cycling changes only which member routes, and
  an ungrouped trip is byte-identical to today.
- **Ops:** `addAlternative(_:to:)` / `addFreeformAlternative(...)` / `cycleAlternative(_:)` /
  `setActiveAlternative(_:)` / `promoteAlternative(_:)` (the mirror of add — extract to a standalone
  stop); deletion and terminals reuse the existing `remove(stopID:)` / `markDone` / `markSkipped`
  (there is no separate `removeAlternative` — §6), each made ring-aware: delete-active-promotes-next,
  per-member terminal leaves a ring-minus-one, one-member-remnant cleanup, deterministic
  effective-winner reconciliation, and ring-wide slot propagation (schedule columns **and**
  `dayRank`). Invariant: exactly one effective active in every ring.
- **App:** the disclosure ring row (firm: current-pick + alternatives; loose: neutral peers)
  with cycle + **promote** controls in `TripItineraryView`; the muted-on-expand canvas pins;
  `StopMenu` "Add as alternative to…" / "Add alternative"; `swiftui-specialist` checkpoint; device
  install on the iPad Pro 13-inch (M5) sim ([[preferred-review-sim]]).
- **No CloudKit sync-registration change** — both columns ride `TripIdea`'s existing registration.
- **AC #7 (existing linear itineraries unchanged):** an ordinary stop is `alternativeGroupID ==
  nil`, `isActive == true` and takes every path exactly as today — the guard is a no-op, and the
  routed core is literally unmodified.

## Slices

- **Slice 1 — schema + active-only partition ✅:** the two columns; effective-active filtering on
  `scheduled` / `itinerary` / `toBeScheduled`; the `alternatives(forStop:)` projection; in-memory
  tests that an inactive member never appears in a day/bucket/leg, that cycling changes only which
  member routes, and that an ungrouped trip is byte-identical to today.
- **Slice 2 — write ops ✅:** `addAlternative` / `addFreeformAlternative` / `cycleAlternative` /
  `setActiveAlternative` / `promoteAlternative` (extract to a standalone stop); ring-aware
  `remove`/`markDone`/`markSkipped`/`unschedule` (delete-active-promotes-next, per-member terminal
  leaves a ring-minus-one, whole-slot unschedule dissolves the ring); remnant/effective-winner
  reconcile; unit-tested for exactly one effective active, stable concurrent resolution, slot
  propagation (incl. `dayRank`), active-only booking/Calendar authority, and multi-promote
  resolution.
- **Slice 3 — UI:** the itinerary **disclosure row** — a firm slot's current-pick + alternatives
  and a loose slot's neutral menu — with tap-to-activate, **promote**, add/remove, an inline
  **cycle** (⟳) control and "N of M" badge; the muted-on-expand canvas pins (no polyline);
  `StopMenu` contextual creation; built for the iPad Pro 13-inch (M5) simulator.
- **Slice 4 — docs:** ROADMAP / trip-canvas / trip-time-model / ADR reconciled (this pass). ADR
  flips to **accepted** only after Slice 3 and package/app/simulator verification.

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
