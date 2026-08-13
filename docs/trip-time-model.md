# Trip time model: undated trips, day numbers, and the start-day solver

*Recovered requirements (2026-06-10) — Jon was mid-build on these in V1/V2.
The schema-shaped parts land in M3; the solver UI can come later, but the data
model must not preclude it.*

## 1. Trips don't require dates

A trip may exist as just a **duration** ("9 days in Denmark"), optionally with
a coarse target (year + season — V1's `YearSeasonPicker` exists for this).
Exact dates bind late, possibly weeks before departure, and may change.

**Schema consequence (M3):** `Trip.startDate` is optional; `lengthInDays` (or
derived) is the stable fact. Nothing downstream may key off calendar dates.

**Refinement (recovered from V1/V2, see recovered-requirements.md #1):** trip
dating is a *pipeline*, not a boolean — `someday(rank) → targeted(year,
quarter) → dated(start)` as one enum. Both prior versions carried
`potentialYear/Quarter/Position` for exactly this.

## 2. The itinerary is day-number-relative

Days, region stops, and scheduling all key off **day number (1…N)**, never
dates. V2's `Schedule` enum already does this (`approximated(DayNumber,
DayPart?)`, `timed(DayNumber, …)`) — that design survives as-is. Assigning or
changing the trip's start date re-derives the calendar view; it never rewrites
the itinerary.

**Intra-day order (ADR-0033).** Within a day, timed/dayparted stops sort by clock
/ band position; a bare-day "Anytime" stop is a *positioned* citizen — it holds a
per-stop `dayRank` (a `Double`, midpoint-insertable) and interleaves by anchoring
to the timed stop it sits after, rather than piling at the day's end. `dayRank` is
intra-day order, not a date — still fully day-relative.

**Alternative slots (ADR-0035).** Interchangeable stops may share a slot. Every
ring member carries the same shared placement (`status`, `dayNumber`, `dayPart`,
`startTime`, `endTime`, and `dayRank`), and writes to that placement propagate to
the full ring in one transaction. Pulling the whole slot back to the shortlist
(`unschedule`) dissolves the ring; a per-member terminal (`markDone` / `markSkipped`)
extracts only that member and leaves the rest a scheduled ring-minus-one.
Reservation facts remain per member — `pinnedDate`, booking metadata, and Calendar
authority do not propagate — so cycling may surface a different option's own
commitment. Exactly one member is **effective active** and therefore enters the
itinerary order; inactive peers remain stored but cannot consume an additional
position, pin number, or travel adjacency. Ring order and concurrent
winner reconciliation use the stable total order `(shortlistRank, id.uuidString)`.
A firm/timed ring may emphasize its current choice while a loose/Anytime ring
may present all peers neutrally, but that is UI mood only — it does not create an
undecided or zero-effective-active state. A `.day(n)` Anytime winner is still a
geographic member of the day's route; only a day-less To-Be-Scheduled ring has no
day route yet.

## 3. The start-day solver (the payoff)

Because the itinerary is day-relative, the start date becomes a **free
variable to play with**: slide the start date / starting weekday and check
whether key stops are *open* on the weekday their day number lands on.
Canonical case: the destination restaurant in the town you reach on day 6 is
closed Mondays — which start dates make day 6 not-a-Monday?

Pieces this needs:
- **Opening days/hours on Idea** (weekday-level granularity is enough for the
  solver; hours are a bonus). Sources: schema.org `openingHours` in the M4
  enrichment pipeline — *the V1 server parsed past this field and skipped it
  (`# Include????` in the restaurant/business mappers); V3 captures it* — plus
  manual entry from day one (M2 field).
- **"Key" flag or implicit rule** — solver checks shortlisted/scheduled stops,
  weighted toward ones marked must-do (shortlist rank can stand in for this).
- **Solver view (M3 stretch / M5):** for each candidate start weekday (7
  cases) or candidate start date range, show conflicts: "Day 6 → Monday →
  Restaurant X closed." Pure function over (itinerary day numbers × idea
  opening days × candidate start date) — a STYLE.md functional-core showcase,
  trivially testable.

**Capture gap — CLOSED (ADR-0029, M6f, 2026-07-02).** The dedicated session
resolved every open question here. The representation is a pure `WeeklyHours`
value type in `GalavantSchema` — seven `DayHours` (`.closed` / `.unknown` /
`.open([ServicePeriod])`), where a `ServicePeriod` carries an optional `Meal`
label **and** an optional clock interval, so meal service (lunch vs. dinner) is
first-class, not re-derived. Structuring happens **at capture**: deterministic
schema.org-token parse first, on-device LLM fallback second, with a hand-editable
structured field as the `.manual` override that wins over re-enrichment; the
free-form string stays the captured source-of-truth alongside it (`Idea` keeps
`openingHours` and gains one additive encoded `structuredHours` column).
`.unknown` is kept distinct from `.closed` so a silent weekday never raises a false
alarm, and the staleness rule below rides the existing `hoursVerifiedAt` stamp.
The solver itself — `StartDaySolver`, pure and meal-aware — is implemented and
tested; the advisory panel lives on the trip. See ADR-0029.

## Status of the third recalled requirement

Stops needing "exact time **or** daypart, not everything scheduled exactly" is
already covered: V2's `Schedule` enum ports in M3 (ADR-0004). No action.

## 4. Booked reservations are absolute facts (refinement, M4)

*Raised by Jon 2026-06-13, after M3c trimmed V2's `.exact(Date, Date,
TimeZone)` out of the `Schedule` enum.* The day-relative rule (§2) is right for
*planned* stops, but a **confirmed reservation** (OpenTable, a hotel, a timed
museum entry) is an absolute fact: it is nailed to a calendar date and must
**not** slide when the trip's start date moves. Day-relative stops should slide;
a booking should not.

This is **not precluded** by the M3c model, and re-introducing exactness is
purely additive (the same nullable-column move M3c used):

- **The time already round-trips.** For a *dated* trip, a booking maps to
  `.timed(dayNumber, "19:30", …)`; `Trip.date(forDay:)` reconstructs the exact
  datetime for display and iCal export. The common path (book *after* dates
  bind) needs nothing new.
- **The gap is the absolute pin, not the time.** Today a stop is pinned to a
  day *number*, so a booking would drift if the trip's start slid. The clean
  fix is an optional `TripIdea.pinnedDate: Date?` (plus booking metadata —
  confirmation #, booking URL, party size, booked-vs-planned) that, when set,
  locks the stop to that date, re-derives its `dayNumber` if the start moves,
  and could even nudge an undated trip toward dating. No enum rewrite.

**Decision:** land with **M4 (capture)** — that's when a share/OpenTable import
actually creates such a stop, and it pairs naturally with the metadata and the
"reservable-from" booking-window work (docs/CURRENT_HANDOFF.md). This *refines* the
day-relative model; it does not re-open it. Until then, bookings are entered as
day-relative `.timed` stops on a dated trip, which is faithful for display.

**Amend — one time authority per stop (ADR-0034, 2026-08-10).** Once Galavant
*ingests* the shared Apple Calendar (roadmap M7), a booked time has exactly **one**
owner, not the three that were latent here (`pinnedDate`, a linked Calendar event, and
a "last reconciled snapshot"):

- **`.manual`** — `pinnedDate` (+ `confirmationNumber` / `bookingURL` / `partySize`)
  is authoritative. A booking the user typed with no Calendar event. Editable in
  Galavant, exactly as this section already describes.
- **`.linked`** — a specific shared-Calendar event is authoritative for the time.
  `pinnedDate` becomes a **read-only cache** of the last observed value, stamped with
  an observed-at instant; the next observation refreshes it. Editing the time means
  editing the Calendar event, not the Galavant copy.

The M5-pinned principle stands (a confirmed booking keeps its real date when the trip
slides); ADR-0034 only fixes *who owns* that date once a booking is Calendar-linked.
**Slice 2 representation (2026-08-11):** `TripIdea.pinnedDate` remains the synced,
read-only cache of the applied Calendar date, while a device-local
`CalendarReconciliationHistoryStore` holds the EventKit event identity, the last
observed commitment, and observed-at instant keyed by stop. If the retained local
identity explicitly finds the event outside the trip window, it records that observed
commitment as moved outside the trip and leaves the itinerary cache unchanged; an
unavailable lookup remains unknown. `CalendarTimeAuthority` is derived from that local
binding (`.linked` when present, otherwise `.manual`), so an EventKit identifier never
enters the CloudKit schema. Slice 3 will add the shared ledger/fingerprint; it must not
turn this device-local binding into a synced identifier.

**Slice 4 projection zone (2026-08-11).** An absolute Calendar instant is placed on
a trip day in the trip's **destination (region) zone**, not the matched venue's zone.
Earlier Slice 4 wording said to "project only through the matched travel place's
explicit MapKit time zone"; dogfooding showed that to be fragile — a bare event title
("Ruby") re-resolves worldwide and can match a same-named place in another zone, which
pushes a just-after-midnight destination event onto the prior civil day and silently
drops it. The region zone *is* the destination zone directly (this section's original
intent: place a home-zone instant on the correct destination day), so it is now the
single civil-day frame for every event shape. Implementation: the model reverse-geocodes
the trip's planning-region bounding-box center (`PlaceMatcher.timeZone(latitude:longitude:)`)
and passes it as the projection zone; a matched venue's own MapKit zone is only a fallback
for a region-less trip, never an override. When neither resolves, the event stays a
visible "Time Zone Needs Review" item rather than falling back to the event/device zone,
and is never silently dropped. The `.manual`/`.linked` authority split above is unchanged.

## Staleness rule

Opening days are scraped-or-typed snapshots and rot. The solver's output is
advisory ("closed Mondays *as of when we saved it*"), and the UI should show
the captured-at date next to any hours-based conflict.
