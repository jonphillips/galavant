# ADR-0047: Booking status is a trip-level fact — not needed, to book, booked

*Status: **accepted** — 2026-09-28; Slices 1–3 implemented in PRs #136–#138. Dogfood 2026-09-28: "I want a
better sense of what is Bookable and what has been Booked or, even more importantly, not."
Gives every trip stop and stay a three-state booking status. You set it by hand; when you
haven't, it is guessed from the kind of place, and evidence of a real booking wins over
both. A trip-wide **"N to book"** rollup surfaces what's still unbooked. Builds on the
pinned-reservation fields (`docs/trip-time-model.md` §4, ADR-0034 time authority) and on
the booking seam `TripStay` left open (ADR-0011). Preserves ADR-0001/0003 (additive synced
columns, no server) and ADR-0004 (booking says nothing about pull lifecycle status).*

## Context

Galavant already knows a little about bookings, but only for stops, and only after the
fact:

- `TripIdea.pinnedDate` — a **confirmed reservation** pinned to its real date
  (trip-time-model §4). Confirmation number, booking URL, and party size are now
  independent details and do not require a pin.
- A stop linked to a shared-Calendar event (ADR-0034) gets its time from Calendar.
  Calendar authority is device-local and is not itself booking evidence; timed events
  also carry the synced `pinnedDate` cache described below.
- Slice 1 adds booking status to `TripIdea` and `TripStay`, plus confirmation details to
  stays, filling the booking seam left open by ADR-0011.

What's missing is the question Jon actually asks while planning: **what still needs
booking?** "Booked" is a fact we can partly detect. "Needs booking" is a judgement, and
it doesn't belong to the place: a café takes reservations, but lunch there on day 3
doesn't need one; the hotel for nights 4–6 does. The same pool idea can need booking on
one trip and not on another. The judgement belongs to **this stop on this trip**.

## Decision

### 1. Three states, stored per trip row, nullable

```swift
public enum BookingStatus: Int, QueryBindable, CaseIterable, Sendable {
  case notNeeded = 0
  case toBook = 1
  case booked = 2
}
```

- `TripIdea.bookingStatus: BookingStatus?` and `TripStay.bookingStatus: BookingStatus?`
  are new nullable INTEGER columns (never renumber; same convention as `TripIdeaStatus`).
  `nil` means **the planner hasn't said**; it is not a fourth state the UI shows.
- `TripStay` also gains `confirmationNumber: String?` and `bookingURL: String?`, filling
  the ADR-0011 seam. A stay's dates are already absolute through its check-in/out days, so
  a stay doesn't need `pinnedDate`.
- These are additive columns on already-synced tables. Existing rows read as `nil`, and
  older builds ignore the new fields; SQLiteData's per-field merge keeps a peer on an
  older build from wiping them.

**Not on `Idea`.** We considered a pool-level "usually needs a reservation" flag and
rejected it for v1. It's wrong often enough (the lunch-café case) that it would need a
per-trip override anyway, and that override is the actual decision. The kind-based guess
(§2) covers most of what a pool flag would have done, without a synced column that
drifts.

### 2. One resolution rule: evidence › explicit › inferred

A pure `BookingStatus.resolve(...)` in GalavantSchema (the functional core; unit-tested)
returns the **effective** status plus where it came from:

```swift
public struct ResolvedBooking: Equatable, Sendable {
  public enum Source: Equatable, Sendable { case evidence, explicit, inferred }
  public let status: BookingStatus?   // nil = undecided (inferred "maybe", see below)
  public let source: Source
}
```

1. **Evidence → `.booked`.** Any of the following means the thing is booked, whatever
   the explicit value says: a `pinnedDate` or a non-empty `confirmationNumber`.
   Evidence uses synced row fields only, never the device-local Calendar time authority
   or reconciliation history. Timed Calendar-linked stops carry a synced `pinnedDate`
   cache; all-day Calendar links have no pin and are not booking evidence. Recording a
   confirmation number can't leave the stop saying "to book".
2. **Explicit.** Otherwise the stored `bookingStatus`, when non-nil.
3. **Inferred from kind.** Otherwise:
   - Every `TripStay` (idea-backed or freeform), `.tour`, `.theater` → `.toBook`
   - An idea-backed stop whose kind is `.stay` → `.notNeeded`; its separate `TripStay`
     carries the lodging booking decision, avoiding a duplicate count.
   - `.food`, `.activity`, `.museum`, `.nightlife` → **undecided** (`status == nil`): a
     *suggestion* to decide, not a claim
   - everything else, and unlocated or kindless freeform stops → `.notNeeded`

The inference table is data in the core, so tuning it is a one-line change with a test,
not a UI change.

### 3. What counts: things you're going to do

The rollup counts rows that are live commitments. That means scheduled stops (on a day
or in To Be Scheduled) and stays, excluding done/skipped/completed ones and past days.
For an alternatives ring (ADR-0035), only the **active** member counts. Considering and
shortlisted rows can carry a status, but they aren't counted: a maybe doesn't need
booking yet.

### 4. Display

- **Row glyph.** Itinerary rows and stay rows/capsules show a small ticket glyph:
  outline = to book, filled = booked, none = not needed. An inferred status draws in a
  secondary tint so a guess never looks like a decision. Undecided shows no glyph on the
  row; it only surfaces in the rollup.
- **Trip header pill: "N to book."** Counts effective `.toBook` (§3). Tapping it opens a
  **To Book** sheet listing, soonest first (day, then time; dayless last):
  1. *To book*: each row with its day, a Book link (`bookingURL` or the idea's website),
     and a one-tap **Mark booked**.
  2. *Decide*: undecided rows (§2 suggestions) with To book / Not needed buttons. This is
     where "food is a suggestion" lives.
  3. *Booked*, collapsed, with confirmation numbers visible (useful at the door).
  The pill hides at zero to-book. A quiet **Bookings** toolbar entry remains whenever
  there are booked rows (so confirmations stay available at the door), and the sheet
  remains reachable while there are undecided rows.
- **Unbooked stays** additionally flag on the lodging capsule bar. An unbooked bed is
  the most expensive thing to discover late.

### 5. Editing

- **Stop editor and stay editor** get a Booking section with a segmented
  *Not needed / To book / Booked* control that writes `bookingStatus`. Choosing Booked
  reveals confirmation # and party size, which **no longer require a pinned date**;
  the booking URL is available for both To book and Booked rows. `setBooking` is split
  so the booking metadata can be written without a pin.
  Pinning the date stays its own toggle, with the same meaning as before ("this
  reservation holds its real date if the trip slides").
- **Row action "Mark booked"** through the existing stop menu (`StopMenu`), not a
  long-press `.contextMenu` on the reorderable row (the paid-for gotcha in
  `docs/handoff/sectioned-reorder-inline-boundaries.md`).
- Setting a confirmation number or pinning a date doesn't write `bookingStatus`; the
  evidence rule (§2.1) already makes it read as booked. Clearing the evidence falls back
  to whatever was stored.

## Consequences

- One source of truth for "is this booked?": `resolve`, the only function any surface
  consults, consumed by projection code (`TripPlan` / the rollup) rather than
  re-derived per view (see the TripPlan recompute hazard: resolve in one batch pass, not
  per row through the model).
- A peer on an older build can't see or set booking status, but won't erase it.
- Calendar-linked stops read as booked without a write. That's correct for a
  reservation, and slightly generous for a planned-but-unbooked Calendar entry. The
  explicit value can't override evidence, so if that turns out wrong in dogfood the fix
  is to narrow the evidence rule, not to add a fourth state.
- Today can later warn about a to-book stop on today or tomorrow. That's out of scope
  here, but it's just another consumer of `resolve`.

## Alternatives considered

- **Pool-level `Idea.needsReservation`.** Rejected (§1): trip-dependent; a pool flag
  needs a trip override anyway.
- **Derive everything, store nothing.** Evidence plus kind covers "booked" and "probably
  needs booking", but can't express "I decided this doesn't need booking", which is the
  state that silences the rollup. The explicit column is what makes the "N to book" count
  trustworthy.
- **Reuse `TripIdeaStatus`** (a `.booked` lifecycle status). Rejected: booking is
  orthogonal to consider → shortlist → schedule (ADR-0004); a scheduled stop is either
  booked or not.

## Scope (build order)

1. Core: `BookingStatus`, `resolve`, inference table, migration (two tables), split
   `setBooking`, stay booking fields. Tests.
2. Editors: segmented control in stop + stay editors; Mark booked in `StopMenu`.
3. Display: row glyphs (itinerary, stays, capsules); "N to book" pill + To Book sheet.
4. Later: Evaluate/handoff contract gains an optional `booking` hint ("book ahead") that
   seeds `.toBook` on commit; Today warning.
