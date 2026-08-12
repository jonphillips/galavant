# ADR-0011: Accommodations are stays, not point stops — a sibling `TripStay` record

*Status: accepted — 2026-06-20*

## Context

ADR-0010 folded freeform stops into the one `TripIdea` record because a freeform
stop **is behaviorally a point stop** — a single day, a single `intraDaySort`
position, born `.scheduled`, sorting among the day's stops. Forking the itinerary
pipeline would have duplicated timing logic "for zero behavioral difference."

An accommodation **inverts** that logic. A stay is *not* a point stop:

- it occupies a **range** (check-in day → check-out day), not a `dayNumber`;
- it is a **recurring anchor** shown on every covered day, not one row in one day;
- it has no single `Schedule.intraDaySort` / `nominalDate` position;
- it drives **home-base context** (and, later, per-day region).

So the same principle that said "one record" for freeform says "**separate
shape**" for stays. Forcing a span into `Schedule` (a `.staying` case, or
`checkIn/checkOut` columns on `TripIdea`) would break the four-column point-in-time
facade `Schedule.dayNumber` returns a single value; a span has none and pollute
every projection that keys off it (`intraDaySort`, `nominalDate`, the now-marker,
`apply(_:)`). trip-time-model §2 makes the itinerary deliberately day-relative and
point-shaped; a stay is the one thing that isn't.

There is also a clean decomposition that mirrors the existing model one level over.
An accommodation is two facts:

- **The place** (a hotel: name, coordinates, category `.stay`, photos) is just an
  `Idea` poolable, capturable, reusable across trips. Nothing new.
- **The stay** (these nights, this trip) is trip-scoped and spans nights. That is
  the new thing the `Idea` ↔ `TripIdea` split, again.

Both prior notes anticipated this: BACKLOG's accommodations entry guessed "likely
its own record (a stay with check-in/out day numbers) rather than a `.timed` stop,"
and trip-time-model §4 already names a hotel as the canonical *pinned booking*.

## Decision

**An accommodation is a `TripStay`: a sibling trip-scoped record that spans nights,
not a `TripIdea` and not a `Schedule` case.**

```swift
@Table public struct TripStay: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tripID: Trip.ID          // the one real FK (rides the trip; cascade-deletes)
  public var ideaID: Idea.ID?         // loose, optional — the pool hotel (ADR-0007)
  public var inlineTitle: String?     // freeform stay (no pool idea), e.g. "Airbnb — conf #…"
  public var inlineNote: String?
  public var checkInDay: Int          // 1…N, required at creation
  public var checkOutDay: Int         // > checkInDay
  public var checkInTime: String?     // optional "HH:mm" (Schedule's convention)
  public var checkOutTime: String?    // optional "HH:mm"
  // Seam for trip-time-model §4: pinnedDate / confirmation# / bookingURL — NOT this slice.
}
```

1. **One real FK → `Trip`** (ADR-0007 single-FK rule), exactly as `TripIdea`. The
   pool hotel is a **loose, optional `ideaID`** UUID, not a SQL FK reconciled on
   read like any orphan. Syncs identically to `TripIdea`; additive new record type.
2. **Resolution reuses `StopContent`** (ADR-0010). A `TripStay` resolves to
   `.idea(idea)` when `ideaID` is set and found, or `.freeform(title, note)` when
   `inlineTitle` is present orphans and malformed entries drop on read, the same
   total mapping `TripPlan.resolve` already performs. A freeform/unlocated stay
   carries no coordinate, so it falls out of the canvas for free.
3. **Freeform stays are allowed** (Q1). A stay may be just a name + nights with no
   pool idea (an unsaved Airbnb, "staying with friends"). `inlineTitle`/`inlineNote`
   carry it, mirroring ADR-0010's freeform stop.
4. **Optional check-in/check-out times** (Q2). Day numbers are required; the times
   are optional `"HH:mm"` strings (Schedule's convention) so two planners can hold
   shared expectations ("check-in 15:00"). Absent a time, the check-in row sorts to
   evening and the check-out row to morning.
5. **Lifecycle: born on the trip, not pulled.** A `TripStay` does **not** travel
   `considering → shortlisted → scheduled` it is created directly, like a freeform
   stop. Two entry points: **"Stay here"** stamps `ideaID` + nights from a pool /
   shortlisted hotel; **"Add lodging"** creates a freeform stay. `checkInDay` is
   required at creation (Q6) there is no spanless stay to render. The referenced
   pool hotel keeps its own idea lifecycle untouched. ADR-0004's pull machinery is
   precisely the part stays opt out of (as ADR-0010's freeform stops do).
6. **Overlap allowed but flagged** (Q5). Two stays may cover the same night
   (changing hotels, a data slip); this is advisory, surfaced like the
   gap-conflict family, never blocked.

### Itinerary representation (I1)

Each day a stay covers gets a quiet **home-base chip** under the day label
("🛏 Hotel Skt. Petri"). The boundaries become real timeline rows: a **check-in
row** on `checkInDay` and a **check-out row** on `checkOutDay`, each sorted by its
optional time (default evening / morning). The middle days carry only the chip
no row. This is the only representation that satisfies all three goals at once:
check-in/out *as events where they happen*, persistent "you're staying here"
context on every covered day, and a per-day home-base hook for later region work.

It stays inside the `List`-section model and extends the existing `ItineraryItem`
enum (`.stop` / `.connector` / `.nowMarker`) with **`.checkIn(stay)` /
`.checkOut(stay)`**. The now-marker continues to key off point stops only; a
check-in/out row with a time participates in ordering naturally, without the marker
having to reason about spans.

*Not this slice:* a spanning banner bracketing the covered days (the literal
"span" visual) fights `List` sections hard and is deferred to a possible
`ScrollView`/`LazyVStack` itinerary (the same rebuild the drag-between-days backlog
contemplates). A top-of-itinerary "Stays" summary band is also deferred (Q7):
chips-only to start; Jon wants to live with the visuals before adding more.

### Canvas representation (M1)

A located stay draws a **distinct off-sequence base pin** (a bed/house glyph in a
neutral style) **unnumbered, not on the day polyline** on every day-lens the
stay covers and on "All." It reads as "the anchor you return to each night," not
"step 3 of a day's route." `locatedStops` / `legs` / `framingCoordinates` stay
untouched (they drive numbering and the polyline); the base is a separate
`MapContent` layer that *optionally* joins `framingCoordinates` so the camera keeps
it in frame. A freeform/unlocated stay draws nothing the same graceful fallout as
a freeform stop.

*Not this slice:* hotel-anchored routing (base → 1 → 2 → 3 → base, travel-time
from base) over-commits assumes every day starts/ends at the hotel and injects
the base into `allLegs` / gap-conflict logic. An attractive future layer.

## Why a sibling record, not a `TripIdea` extension

| Option | Verdict |
| --- | --- |
| **D1 New `Schedule` case / span columns on `TripIdea`** | Rejected. `Schedule` is *defined* point-in-time (trip-time-model §2). A span has no single `dayNumber`; `intraDaySort`, `nominalDate`, the now-marker, and the four-column facade all assume a point. Pollutes the tested functional core to model something it explicitly isn't. |
| **D2 Sibling `TripStay` (chosen)** | Span is first-class; `Schedule` stays pure. Syncs identically to `TripIdea` (one FK to `Trip`). Reuses `StopContent` resolution, orphan reconciliation, and the freeform shape so the "parallel pipeline" cost ADR-0010 feared doesn't apply: the stay projection is *genuinely different* logic (span / anchor), not a re-sort of the same point stream. |
| **D3 Reuse the `TripIdea` table + a discriminator + span columns** | Rejected. One row would carry two mutually-exclusive placement systems (the `Schedule` columns *or* `checkIn/checkOut`) an impossible-states magnet (STYLE §3) that muddies the model ADR-0010 just settled. The saved CloudKit record type isn't worth overloading the record. |

The contrast with ADR-0010 is the whole point: ADR-0010 chose one record because a
freeform stop is *the same behavior* as a point stop; ADR-0011 chooses a sibling
because a stay is *a different behavior*. The difference belongs in the record,
not hidden behind a discriminator on a shared one.

## Scope deferred (clean seams, decided this session)

- **Booking metadata / `pinnedDate`** (trip-time-model §4): option (b) model the
  span cleanly now, leave a documented seam (`pinnedDate`, confirmation #, booking
  URL, booked-vs-planned). It lands when capture/OpenTable import actually creates
  a booking; not entangled with this design.
- **Per-day region driving:** display-only this slice (Q4). The home-base chip
  *shows* the base; the deferred per-day-regions design consumes it later (it does
  not yet drive the day's map framing).
- **"Stays" summary band (I4)** and **spanning banner (I2)**: not now (Q7).
- **Hotel-anchored routing (M2):** the broad base → all stops → base route remains
  deferred. **Refined 2026-08-11:** the small but high-value first leg is now in
  scope: a located lodging supplies directions to the first located itinerary
  stop. A transition day resolves the source from timeline order: before check-in
  it is the departing stay; afterward it is the arriving stay. Its check-out →
  check-in transfer gets its own ETA/open-in-Maps row whenever those boundary
  events are adjacent (a stop genuinely between them suppresses only that direct
  transfer). Neither connector is a sequence pin or a claim that every day begins
  at the hotel.

## Relationship to prior decisions

- **ADR-0004 (pull lifecycle):** unchanged. Stays opt out of `considering →
  shortlisted → scheduled`, exactly as ADR-0010's freeform stops do.
- **ADR-0007 (single-FK sharing rule):** honored one real FK to `Trip`, a loose
  optional `ideaID`. `TripStay` is a new leaf on the `TravelParty`-rooted tree.
- **ADR-0010 (`StopContent`):** reused for `.idea` / `.freeform` resolution; its
  one-record reasoning is deliberately inverted here (see table above).
- **ADR-0035 (itinerary backup plans):** weighs this sibling-record pattern and
  **declines it** — a backup's whole relationship is one pointer, so it uses a single loose
  `TripIdea.backupForStopID` column rather than a `TripStay`-style side table (see that ADR's
  "Why not" table).
- **trip-time-model §2/§4:** day-relative span (§2-consistent); `pinnedDate` is the
  §4 seam, deferred.

## Consequences

- **Schema:** a new `TripStay` table + CloudKit record type additive and
  sync-friendly (single FK, new optional fields), not the rename ADR-0010 avoided.
- **Read-model:** new `TripPlan` projections `stays`, `stays(coveringDay:)`,
  and located-stay framing reuse `StopContent`/`resolve`; the point-stop
  projections (`itinerary`, `legs`, `locatedStops`, `framingCoordinates`) are
  untouched.
- **Itinerary:** new `ItineraryItem.checkIn` / `.checkOut` cases; home-base chip in
  the day-section header; check-in/out rows sorted by optional time.
- **Canvas:** a new off-sequence base-pin `MapContent` layer; numbered routes
  unchanged.
- **Write path:** `TripStay.create` (from a hotel idea) / `createFreeform` /
  `edit` ops; a "Stay here" affordance on a hotel idea/shortlist row and an
  "Add lodging" action; `checkInDay` required, `checkOutDay > checkInDay`
  validated; overlap flagged advisorily.
- **Open at build (visual):** exact chip styling and the check-in/out row
  sort defaults Jon will spend time with the visuals before finalizing.
