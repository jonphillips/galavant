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
"reservable-from" booking-window work (docs/BACKLOG.md). This *refines* the
day-relative model; it does not re-open it. Until then, bookings are entered as
day-relative `.timed` stops on a dated trip, which is faithful for display.

## Staleness rule

Opening days are scraped-or-typed snapshots and rot. The solver's output is
advisory ("closed Mondays *as of when we saved it*"), and the UI should show
the captured-at date next to any hours-based conflict.
