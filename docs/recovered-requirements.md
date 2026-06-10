# Recovered requirements — struct/enum archaeology of V1+V2

*Second sweep (2026-06-10), reading domain models field-by-field. Each item:
where it was found, what it implies, and its V3 disposition.*

## 1. The potential-trip pipeline (adopt — extends trip-time-model.md)

V1 `Trip` carries `potentialYear`, `potentialQuarter`, `potentialPosition` and
`ScheduleSpecificity` (unknown → season/year → exact); V2 kept all of it as
`DepartureCertainty` + `startDateString`/`durationDays`. So undated trips
weren't just "no date yet" — **trips themselves form a ranked backlog**:
someday-trips ordered by `potentialPosition`, coarsely targeted to
year+quarter, graduating to dated. V3 adopts: Trip has a certainty lifecycle
(`someday(rank) → targeted(year, quarter) → dated(start)`) — an enum, per
STYLE.md §3. The trips list groups by certainty; someday-trips are
drag-rankable like the shortlist.

## 2. The flames scale (adopt — this is the solver's "key stop" weight)

V1 `NoteRating` / V2 `Attraction.Rating`, identical semantics: **Must Do /
Want to Do / Could Do / Do Not Do / Decide Later**. A *pre-visit priority*,
distinct from any post-visit verdict. V3 adopts it as Idea's priority scale
(M2); it feeds shortlist default-ordering and the start-day solver's
weighting (trip-time-model.md §3 "key" rule: Must Do conflicts are loud,
Could Do conflicts are whispers).

## 3. Pre-visit note vs post-visit review (adopt the split; see open Q1)

V1 `Place` separates `myNote` (pre-visit: rating + body + visited) from
`myReview` (post-visit verdict), plus `collaboratorNotes`/`collaboratorReviews`
arrays — opinions were per-person even in V1. → resolved his-and-hers, **Q1 below.**

## 4. Booking windows (adopt field; see open Q2 for ambition)

V1 `Supplemental.reservableAt` — *when reservations open* — plus
`BookingDetails.confirmationNumber` on activities. Recovered intent: key
restaurants/tours open booking 30–90 days out; the trip needs to know
*bookable-from* dates, and a stop records its confirmation number once
booked. → resolved, **Q2 below.**

## 5. Stop taxonomy confirms the placeless-stop entity (adopt)

V2 `EventType`: `activity(ActivityType) / dining / lodging / transit` — an
enum with a nested associated value (the keeper shape). `transit` and
`lodging` as first-class kinds confirms M3's open question leans toward a
real Stop entity: flights, transfers, check-ins have no pool Idea behind
them. (ADR-0006 "Open" section stands; this is evidence, not a decision.)

## 6. `RegionStop.percentDay` (adopt)

Both V1 and V2: a day's region stops carry a fraction (morning Copenhagen
0.4 / afternoon Roskilde 0.6). Itinerary days can split across regions —
the day-lens map view (trip-canvas.md) should render split days.

## 7. Trip link bookmarks (adopt, trivial)

V2 `Bookmark` (label + URL) attached to trips — reference links (the Airbnb
listing, the ferry schedule, a guide post) that aren't Ideas. Cheap and
useful; M3.

## 8. Smaller recoveries

- **Dual coordinates with provenance** (V1 `Place`): scraped lat/lng kept
  separate from `appleMaps*` coords + name; display prefers Apple. Adopt in
  the M4 matching pipeline (scraping-enrichment.md) — don't overwrite the
  scraped signal with the match.
- **V2 `POICategory`** (19 values, bakery→winery): the starting vocabulary
  for `Idea.kind` (ADR-0006), merged with the EventType lens.
- **`mapDisplayColor` / `mapDisplayPriority`** (V1): per-item pin color and
  declutter priority — fold into M2 pool-map design as needed.
- **`TripSetting.timeFormat`** (V1+V2): per-trip 12/24h display — traveling
  where the other convention rules. Tiny; M3 polish.
- **`Trip.completed`** flag → superseded by certainty lifecycle + past dates.
- **`Supplemental.cuisine`** → just a field on Idea (or a tag); M2.

## Deliberately not recovered

Trip "dreaming" metadata (V1 `TripProximity`, `TravelActivity`,
`TravelCompanion`, `TravelBudget`): mood-board attributes for browsing dream
trips. For a two-person household, companions is a constant, and
budget/proximity never fed any mechanism in V1 — classification for its own
sake. **Skip** unless real use emerges; the potential-trip pipeline (#1)
covers the "dreaming" need with rank + quarter.

## Resolved questions (2026-06-10)

- **Q1 — opinions are his-and-hers.** Each Idea can carry a flames rating +
  note *per spouse*, both always visible — the shortlist negotiation is
  explicit ("you said Must Do, she said Could Do"). Post-visit review is a
  single shared verdict. Note vs ADR-0003: this is *attribution*, not
  ownership — both spouses still read/write everything; there is still no
  `mine` flag, just an author on each opinion.
- **Q2 — booking windows surface on dated trips** (M3): `reservableFrom` on
  Ideas, confirmation number on Stops, and a "bookable now / opens in N days"
  section on dated trips. **Held for the future, explicitly wanted:**
  local-notification reminders when a Must-Do's booking window opens — Jon
  chases hard-to-get restaurants and wants waking up in the middle of the
  night to book to be an option. When built, alerts need time-of-day
  precision (booking windows open at a specific local time), not just a date.
- **Q3 — potential-trip pipeline adopted** as written in #1.
