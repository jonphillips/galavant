# Effort — Trip lens: see the trip's lunches, dinners, and nights from the guide

**Status:** Ready · **Summary:** Slice 3.2 of [ADR-0053](../../decisions/0053-taste-record-and-region-guide.md) (D8). When
the guide's region falls on a trip's days, a strip above the cards shows that trip's lunch and dinner slots on those days
(Dining), or its nights (Hotels). Cards already on the trip carry a badge saying where. Read-only: filling slots is
[`guide-slot-filling`](guide-slot-filling.md). No schema, migration, sync, or hand-off change.

**Read first:** ADR-0053 D8; the mockup [`region-guide-trip-lens.html`](../../mockups/region-guide-trip-lens.html), frames 1,
3, and 4; ADR-0035 (rings: exactly one effective active member); ADR-0012 (per-day regions); `trip-time-model.md` §2 (day
numbers, never dates).

**Depends on `guide-dossier-panel`.** Start from a `main` that has it.

## Today

- `TripDayRegion` assigns a `MapRegion` to a trip day. `TripPlan.region(forDay:)` resolves it, and orphans drop out.
- `TripPlanInputs` and `TripPlanSnapshot` (`TripPlanSnapshot.swift`) build one trip's `TripPlan` once and reuse it while
  the inputs are equal. That's the fix for the itinerary freeze, and the guide must use it, not build a plan per access.
- `TripPlan` resolves stops and rings: `itinerary`, `alternatives(forStop:)`, and the ordering helpers. `stays`,
  `stays(coveringDay:)`, and `TripStay.nights` give lodging per night. The last trip day has no night.
- `Schedule` is `.unscheduled`, `.day(n)` (Anytime), `.daypart(n, part)`, or `.timed(n, start:end:)`. `DayPart` has
  `.lunch` and `.dinner`. `Meal.forClock(minute:)` already maps a clock time to a meal.
- `TripIdea.bookingStatus` (`.booked`) and `TripStay.bookingStatus` say what's booked.
- `Trip.sectioned(_:now:calendar:)` splits trips into dated, targeted, someday, and completed.
- `IdeasListModel.guideButtonTapped()` builds `RegionGuideScope` and already knows `activeTrip`.
- `IdeaTripBadge` is the Ideas cell badge across *all* trips. The guide's badge is narrower (one trip, with the slot), so
  don't stretch that type.

## Part 1. The read-model (`GalavantSchema`)

```swift
public struct GuideTripLens: Equatable, Sendable {
  public struct TripChoice: Identifiable, Equatable, Sendable {
    public var id: Trip.ID
    public var name: String
  }

  /// One stop as a slot shows it. For a ring, this is the effective-active member.
  public struct SlotStop: Identifiable, Equatable, Sendable {
    public var id: TripIdea.ID
    public var ideaID: Idea.ID?
    public var title: String              // idea name, or the freeform title
    public var isFreeform: Bool
    public var isBooked: Bool             // bookingStatus == .booked
    public var optionCount: Int           // ring size; 1 for a lone stop
  }

  public enum MealCell: Equatable, Sendable {
    case open
    case filled([SlotStop])               // non-empty, in intra-day order
  }

  public struct MealDay: Identifiable, Equatable, Sendable {
    public var day: Int
    public var weekday: Weekday?          // nil on an undated trip
    public var date: Date?
    public var lunch: MealCell
    public var dinner: MealCell
    public var alsoThatDay: [SlotStop]    // Anytime food stops, so they aren't forgotten
    public var id: Int { day }
  }

  public enum NightRun: Equatable, Sendable {
    case stay(stayID: TripStay.ID, ideaID: Idea.ID?, title: String, isBooked: Bool, nights: ClosedRange<Int>)
    case open(nights: ClosedRange<Int>)
  }

  public enum Body: Equatable, Sendable {
    case meals([MealDay])
    case nights([NightRun])
  }

  public enum Badge: Equatable, Sendable {
    case meal(day: Int, Meal, ringActive: Bool?)   // nil for a lone stop
    case nights(ClosedRange<Int>)
    case onTrip                                    // pulled, not in a slot
  }

  public var trip: TripChoice
  public var otherTrips: [TripChoice]               // for the chip's menu
  public var regionDays: [Int]
  public var body: Body
  public var badges: [Idea.ID: Badge]

  public static func candidates(
    region: MapRegion, trips: [Trip], dayRegions: [TripDayRegion], now: Date, calendar: Calendar
  ) -> [TripChoice]

  public init(
    trip: Trip, candidates: [TripChoice], region: MapRegion, category: GuideCategory,
    plan: TripPlan, calendar: Calendar)
}
```

Pinned:

- **Candidates.** A trip is a candidate when at least one of its `TripDayRegion` rows names this region and it isn't in
  `sectioned(…).completed`. Order them dated, then targeted, then someday, as `sectioned` does. No candidates means no lens,
  and the guide looks exactly as it does today.
- **Which trip shows.** The scope's preferred trip if it's a candidate, else the first candidate, else the user's last pick
  from the chip during this screen's life. `RegionGuideScope` gains `preferredTripID: Trip.ID?`, set from
  `IdeasListModel.activeTrip`. Put the choice in a pure function and test it.
- **Region days** are the trip's days whose `TripDayRegion` is this region, ascending. They don't have to be contiguous.
- **Meal slots, for each region day.** A scheduled stop on that day belongs to a slot when:
  - its schedule is `.daypart(day, .lunch)` or `.daypart(day, .dinner)`, or
  - it's `.timed(day, start, _)` and `Meal.forClock(minute:)` of `start` is `.lunch` or `.dinner`.

  Kind doesn't matter: whatever is in the lunch slot is shown, freeform or not. A ring appears **once**, as its
  effective-active member with `optionCount` set to the ring's size. A ring member never shows as its own entry.
- **Anytime (`.day(n)`) stops** go in `alsoThatDay`, but only food stops (`IdeaKindGroup.food`), so a museum doesn't
  clutter the dining strip. Other dayparts (breakfast, evening, …) are ignored.
- **Weekday and date** come from `Trip.date(forDay:)`. Add `Weekday(date:calendar:)` if nothing like it exists. On an
  undated trip both are nil, and the row reads "Day 5".
- **Nights.** The nights are the region days, minus the trip's last day. Walk them in order, and group consecutive nights
  that the same stay owns (`TripPlan.stayID(owningDay:)`'s rule) into one `.stay` run, and consecutive unowned nights into
  one `.open` run. A stay's run covers only the region's nights, even if the stay runs longer.
- **Badges, for this trip only.** A scheduled stop in a meal slot gives its idea `.meal`, with `ringActive` set for ring
  members. A stay gives its idea `.nights`. Any other `TripIdea` on the trip that isn't declined, done, or skipped gives
  `.onTrip`. If an idea qualifies twice, the meal or night badge wins.
- **One pass.** The init walks the plan's entries and stays once, into dictionaries. The model builds the plan through a
  stored `TripPlanSnapshot`, and the view builds the lens **once per body, ahead of the `List`**, next to the guide.

## Part 2. The strip and the badges (app target)

`RegionGuideModel` gains fetches for trips, trip ideas, stays, day regions, calendar constraints, and alternative groups,
which are the `TripPlanInputs` it needs, plus a stored `TripPlanSnapshot` and the chosen trip.

- **Strip placement:** at the top of the list column, above the shelf sections and below the header. The same on iPad and
  iPhone, but laid out differently:
  - **iPad (regular):** a grid with a day label column, then **Lunch** and **Dinner** (mockup frame 1). On Hotels, one column
    of night runs, with a stay spanning its nights (frame 4).
  - **iPhone (compact):** a horizontal row of day cards, each with an L and a D line (frame 3). On Hotels, one card per run.
- **Strip header:** a trip chip (the trip's name; a menu of `otherTrips` when there are any) and "Days 4–7 in Val Serena" (or
  "Nights …" on Hotels). A chevron folds the strip to just its header. Remember that per device with
  `@Shared(.appStorage("regionGuideLensFolded"))`.
- **Cells:**
  - **Booked:** green, with a check.
  - **A ring:** amber, "Ca' del Larice · 2 options".
  - **Freeform:** italic.
  - **Open:** a dashed outline that says "Open".
  - **Several stops in one slot:** the first one's name plus "+1".
  - `alsoThatDay` stops sit as one small line under the day ("Also: Gelateria Nord").
- **Taps (read-only for now):** tapping a filled cell or a stay opens that stop's dossier through the same destination a
  card uses. That's the active member for a ring. A freeform stop has no dossier, so its cell does nothing. Open cells do
  nothing until `guide-slot-filling`.
- **Card badges:** a capsule at the card's top trailing corner. Use the meal's weekday when the trip is dated: "Wed dinner",
  "Wed dinner · active", "Nights 4–6", "On trip". On an undated trip, it's "Day 5 dinner". Format the labels in the package,
  and test them.
- **The map is unchanged** in this slice.

## Tests

**Package:**

- Candidates: a trip with no day in the region, a completed trip, and dated, targeted, and someday trips. The right set, in
  the right order.
- The trip-choice function, every branch.
- Meal slots: `.daypart` lunch and dinner, `.timed` at 12:30 and 19:30 (in), and at 09:00 and 16:59 (lunch, by
  `forClock`). A `.day(n)` food stop goes to `alsoThatDay`, and a `.day(n)` museum is absent. A breakfast daypart is absent.
- Rings: a 3-member ring at dinner gives one `SlotStop` for the effective-active member, with `optionCount` 3. All three
  ideas get `.meal` badges, and only one has `ringActive` true.
- Nights: region days 4–7 on a 7-day trip give nights 4–6 only. A stay covering 3–6 gives one run, 4–6. A gap gives an open
  run. Two stays back to back give two runs.
- Undated trip: weekday and date are nil. Dated: the right weekdays.
- Badges: meal beats on-trip. A declined or done stop gives no badge.

**App target:** `RegionGuideModel` over the in-memory database gives the same lens as `GuideTripLens` built from the same
rows. Switching trips from the chip rebuilds it. A region with no trip days gives no lens.

## Out of scope

- Writing anything: Add to Trip, choosing an option, Stay here, and slot focus. Those are
  [`guide-slot-filling`](guide-slot-filling.md).
- The mockup's hatched "Travel day" cell. Galavant has no travel-day fact, so don't invent one.
- Distance to the night's hotel (`guide-slot-filling`).
- Changing the Ideas list's own badges.

## Done when

- A region with trip days shows the strip on Dining and Hotels, on iPad and iPhone. A region without trip days shows the
  guide exactly as before.
- The cells, badges, and night runs come from one `GuideTripLens` per body, over a snapshot-built plan.
- Every test above is green, and the guide, dossier, plan, and alternatives tests pass unchanged.
- `scripts/check-drift.sh` passes, and the app-target tests ran headless and passed (`verification.md`). Compile only, with
  no simulator walkthrough.
- The closeout carries this gate, word for word, with `--gate`:

  > **Trip lens (`guide-trip-lens`).** On the iPad, TestFlight build. Open the Guide on a region your next trip has days in.
  > The strip shows those days' lunches and dinners, and matches the trip's itinerary: booked ones green, a slot with options
  > amber with its count, open ones dashed. Cards on the trip say where. Switch to Hotels: the nights, with a stay spanning
  > its nights and any night with no stay marked. Fold the strip, leave, and come back: still folded. Pick a region with no
  > trip days: no strip. On the iPhone, the strip is a row of day cards. **Then judge:** Does the strip earn its height above
  > the cards? Is anything you'd want to know about a day missing?
