# Effort — Plan snapshot: stop rebuilding the plan while the itinerary renders

**Status:** Done (2026-11-07) · **Summary:** Revives Phase 2 of [plan-memoization](plan-memoization.md) with a different
mechanism. `TripPlanningModel.plan` becomes a stored snapshot keyed on the arrays it's built from, and the itinerary derives
everything its rows need in one pass per list. `StopRow` stops calling back into the plan during `body`. No schema, migration,
sync, or product change.

**Read first:** [archive/plan-memoization.md](plan-memoization.md),
[ADR-0038](../../decisions/0038-journey-today-projections-and-weather.md), and the `.onScrollGeometryChange` entry in
[KNOWN-ISSUES.md](../../KNOWN-ISSUES.md).

**No ADR.** This implements the existing functional-core / observable-shell decision, and `TripPlan` stays an ordinary value.
That's the line the Phase 2 write-up drew for needing one.

## Why now

PR 215 fixed the iPad freeze by removing `.onScrollGeometryChange`. The rebuilds below didn't cause that regression, but they
make every render expensive on stop-heavy trips. A device trace before the fix, two 1.3-second clips of a Debug build so
indicative only, showed this share of main-thread time:

| Share | Where | Why |
| ---: | --- | --- |
| 39% | `StopRow` `.accessibilityActions` | `canMoveStopEarlier` and `canMoveStopLater` each rebuild the plan and its itinerary, per row |
| 8% | `StopRow` body | `model.plan.alternatives(forStop:)`, per row |
| 22% | `fullItinerary` | `itineraryItems` and `locatedSequenceNumbers` each re-derive the itinerary, per day |
| 4% | `HomeBaseRow` call site | `model.plan.overlappingStayIDs`, per row |

**A snapshot alone isn't enough.** `itinerary`, `stays`, `overlappingStayIDs`, and the rings are computed properties on
`TripPlan`, so a stored plan still re-derives them on each read. Most of the win comes from the one-pass list in Part 2. The
snapshot removes the plan construction under every other reader. Both are in scope.

## The Phase 2 design doesn't fit: why this brief doesn't use `FetchKeyRequest`

Phase 2 proposed a `TripPlanRequest` read through `@Fetch`. Checked against today's code:

| Phase 2 said | Now |
| --- | --- |
| Eight tables feed the plan | Still true. `TripPlanningModel.plan` reads the same eight |
| Don't add lazy storage to `TripPlan` | Still right, and stronger: `CalendarReconciliationModel+Promotion.swift:148` mutates a copy's inputs, so stored projections would go stale |
| No ADR | Still right |
| A key built from the arrays costs O(all rows), which approaches the work saved | **Wrong.** `Array ==` returns without comparing elements when both sides share a buffer, and `FetchAll.wrappedValue` returns the same buffer until the query publishes again. A probe on this toolchain over two 5,000-row arrays made 0 comparisons for shared buffers and 5,000 for equal contents in a new buffer, in both `-Onone` and `-O` |
| A one-frame mismatch between plan and raw arrays is acceptable | It's avoidable. `plan` is built from the same arrays as `entries`, `trip`, and the others, so today they can't disagree within a frame. A second observation gives that up to solve a problem that no longer needs it |
| The extra observation costs duplicate reads | Still true. It would be the model's 21st `@FetchAll`-style observation, rereading the whole `Idea` and `MapRegion` tables on each relevant write. The model has to keep those arrays for Add, the lens, and editors |

Phase 2's other alternative, a manual `withObservationTracking` cache with a generation counter, stays rejected. Its risk was
losing observation on a cache hit. This design can't lose it, because **every access still reads every input** through its
`@FetchAll` wrapper. That read registers the dependency, and a hit only skips the build.

`FetchKeyRequest` would earn its place if building the plan had to move off the main thread. Nothing here says it does: an
August measure put the getter's whole construction at about 0.12 ms in an optimized build on a 240-stop fixture (macOS, not a
device), and this design builds once per change.

## Part 1. The snapshot (`GalavantSchema`, then the model)

```swift
public struct TripPlanInputs: Equatable, Sendable {
  public var tripID: Trip.ID
  public var lengthInDays: Int
  // Each array exactly as its @FetchAll publishes it: unfiltered and unsorted.
  public var tripIdeas: [TripIdea]
  public var ideas: [Idea]
  public var tripStays: [TripStay]
  public var dayRegions: [TripDayRegion]
  public var regions: [MapRegion]
  public var calendarConstraints: [CalendarTripConstraint]
  public var alternativeGroups: [TripAlternativeGroup]
}

extension TripPlan {
  public init(_ inputs: TripPlanInputs)  // the trip filter and lookups the getter does today
}

public struct TripPlanSnapshot: Sendable {
  public private(set) var buildCount = 0
  public init()
  public mutating func plan(for inputs: TripPlanInputs) -> TripPlan
}
```

Pinned:

- **Key on the raw arrays, never the filtered ones.** Filtering allocates a new buffer on every access, which loses the
  identity shortcut and makes each hit O(rows). The cost is that an edit to another trip's rows rebuilds this plan once, to an
  equal value. That's fine.
- **No partial keys:** no counts, endpoint IDs, hashes, or timestamps. Equality over the whole inputs is the invalidation.
- **Adopt the incoming inputs on an equal comparison**, so a republish with unchanged contents costs one O(rows) comparison
  and the next access is back on shared buffers.
- `TripPlan.init` builds exactly as it does today, and `TripPlan` itself doesn't change shape: inputs stay `var`, projections
  stay computed.

In `TripPlanningModel`:

```swift
@ObservationIgnored private var planSnapshot = TripPlanSnapshot()
var planBuildCount: Int { planSnapshot.buildCount }

var plan: TripPlan {
  planSnapshot.plan(for: TripPlanInputs(/* reads trip and all seven arrays, every access */))
}
```

The getter writes only to `@ObservationIgnored` storage, so reading `plan` during `body` doesn't mutate observed state. Key on
`trip?.lengthInDays ?? 1`, so editing another `Trip` field doesn't rebuild.

Leave `legIdentities(for:basedOn:)` in `TripPlanningModel+Scheduling.swift` alone. It deliberately builds its own plan from
rows read inside the write transaction. The promotion path keeps mutating its copy.

## Part 2. One derivation per list (`GalavantSchema`)

A new pure value holds everything the itinerary's rows ask for, built in one pass:

```swift
public struct ItineraryStopFacts: Equatable, Sendable {
  public var ring: ResolvedAlternativeRing?
  public var canMoveEarlier = false
  public var canMoveLater = false
}

public struct ItineraryList: Equatable, Sendable {
  public struct Day: Identifiable, Equatable, Sendable {
    public var number: Int
    public var stops: [ResolvedStop]
    public var items: [ItineraryItem]
    public var sequence: [TripIdea.ID: Int]
    public var id: Int { number }
  }
  public var toBeScheduled: [ResolvedStop]
  public var days: [Day]
  public var overlappingStayIDs: Set<TripStay.ID>
  public var showsSketchPrompt: Bool
  public func facts(forStop id: TripIdea.ID) -> ItineraryStopFacts  // default facts when absent
}

extension TripPlan {
  /// `focusedDay` nil builds every day. Set, it builds that day only.
  public func itineraryList(
    focusedDay: Int?,
    overrides: [LegIdentity: TransportMode],
    mainMode: TransportMode?,
    travelTimes: [LegKey: [TransportMode: TravelTime]],
    autoSwitchThreshold: TimeInterval,
    now: Date?,
    tripStartDate: Date?
  ) -> ItineraryList
}
```

Pinned:

- **A `package` overload takes the shared derivations as closures**, the way `allLegPairs(itinerary:stays:)` already does:
  `resolvedStops`, `stays`, and `rings`. The public function passes the real ones. This is the test seam.
- **Each closure is called exactly once per build.** That one resolved-stop list feeds `toBeScheduled`, every day, and
  `showsSketchPrompt`, which is today's `!hasScheduledStops && dayRegions.isEmpty`. Effective modes come from
  `allLegPairs(itinerary:stays:)` over those same values, so the list doesn't hide a second graph walk behind `legModes`. A
  focused-day build still resolves the whole trip's modes, as it does today.
- **A focused build always returns one `Day` for `focusedDay`**, even when that day is outside the itinerary, because
  `itineraryItems(forDay:)` answers for any day today.
- **The existing public functions keep their signatures and delegate to the shared internals**, so the logic doesn't fork:
  - `itineraryItems(forDay:…)` splits into a lookup and an internal that takes the day's stops.
  - `locatedSequenceNumbers(forDay:)` gets the same split.
  - `legModes` shares its resolution with the list.
  - Today and the other callers keep calling them unchanged.
- **Move rule, in one place.** Lift the body of `reorderedIDs` (`TripPlanningModel+Scheduling.swift`) into a pure static over
  an ordered stop list. The list computes each stop's two flags from it with one walk of each day. The model's `reorderDay`
  calls the same static, over `orderedStops(onDay:)`, when someone actually taps.
- **Rings cover every entry**, not just the visible winners, so a To Be Scheduled stop or a non-winning member gets the same
  answer `alternatives(forStop:)` gives. A stop that isn't a bare `.day` stop in a day's visible order gets both move flags
  false.

## Part 3. The views

- Add `func itineraryList(focusedDay: Int?) -> ItineraryList` to the model. It reads `plan`, `currentModeOverrides`,
  `trip?.mainTransportationMode`, `travelTimes`, `now`, and `trip?.startDate`.
- `TripItineraryView.fullItinerary` and `focusedDayList` call it **once, ahead of the `List`**, and read everything from the
  result. The whole-trip list loops over `list.days`, and `HomeBaseRow` gets
  `list.overlappingStayIDs.contains(stay.id)`. `TripItineraryView.swift` ends up with no `model.plan` read. The read inside
  `itineraryList` still happens during `body`, so a data change still invalidates the view.
- `StopRow` takes `facts: ItineraryStopFacts`. It reads `facts.ring` and disables the accessibility actions from
  `facts.canMoveEarlier` and `facts.canMoveLater`. Pass the facts through `StopRowAccessory` and `StopMenu` to
  `StopMenuActions`, which makes the same two checks. Otherwise the cost just moves down a level.
- Delete `canMoveStopEarlier` and `canMoveStopLater` once nothing calls them. `moveStopEarlier` and `moveStopLater` stay and
  still decide from the current plan at tap time.
- `StopRow` keeps `model` for actions, the selection tint, and disclosure state. Those are direct property reads.
- **Add a lint rule so this can't come back** (`check-drift.sh` runs SwiftLint with `--strict`, so a warning blocks). Follow
  `view_persistence` in `.swiftlint.yml`:

  ```yaml
  itinerary_row_plan_read:
    name: "Plan read in the itinerary list"
    regex: 'model\.plan\b|canMoveStop(Earlier|Later)\('
    included: ".*/Trips/(TripItineraryView|TripItineraryRows|TripItineraryDayHeader|PlanningRow|StopMenu)\\.swift"
    message: "Itinerary rows read ItineraryList, built once per list. A plan read here runs once per row."
    severity: warning
  ```

- Fix any comment that still says the plan rebuilds per access. Check `TripPlanningModel+Now.swift`,
  `TripPlanningModel+Sketch.swift`, `TripPlanningModel+Directions.swift`, `TripPlanningView.swift`, and
  `TripItineraryView.swift`.
- A new source or test file means running `xcodegen generate` and committing `project.yml` and the pbxproj per
  [verification.md](../../verification.md).

## Tests that count derivations

**Package (`GalavantSchemaTests`)**

- `TripPlanSnapshot`:
  - Repeated reads of the same inputs give `buildCount == 1`.
  - **A change to each of the nine inputs rebuilds.** Each of the seven arrays is edited in place, with the same count and same
    IDs and one field changed. Parameterize it. This is the test partial keys would fail.
  - Equal contents in new buffers don't rebuild.
  - A plan built from inputs equals one built the way the old getter did, including rows from another trip being filtered
    out and duplicate idea IDs keeping the first.
  - A small test with a comparison-counting element asserts that `==` on shared buffers makes zero comparisons, so a change to
    that behavior fails here rather than as a mystery hitch.
- `ItineraryList`:
  - **`largeListDerivesSharedInputsOnce`:** the existing 40-day × 6-stop fixture, next to `largeTravelGraphDerivesSharedInputsOnce`.
    Each closure's count is exactly 1, with whole-trip and focused-day builds both covered.
  - **Equivalence against the existing public API** on a fixture with stays, overlapping stays, a changeover, rings, calendar
    constraints, an unlocated stop, To Be Scheduled stops, and a now marker. For every day, `items` equals
    `itineraryItems(forDay:…)` given `legModes`, and `sequence` equals `locatedSequenceNumbers(forDay:)`. `overlappingStayIDs`
    matches the plan's. For every entry, `facts.ring` equals `alternatives(forStop:)`.
  - Move flags: first, middle, and last Anytime stop; a one-stop day; timed and dayparted stops; unscheduled; a ring winner; and a
    non-winning ring member.

**App target (`GalavantTests`, in-memory database)**

- Many reads of `plan` and one `itineraryList` give `planBuildCount == 1`. Writing a stop and running
  `try await model.$allTripIdeas.load()` gives 2, and the plan reflects the write. Writing an unrelated row, a `Tag`, leaves it
  at the same count.
- Two reads of `model.allTripIdeas` with no publish between them share a buffer (compare `withUnsafeBufferPointer` base
  addresses). The cost argument above rests on this, and only this test pins it for the real `@FetchAll` path.
- **Observation survives a hit.** Read `plan` once to fill the snapshot. Read it again inside `withObservationTracking`, which
  is a hit. Write a stop and load. The `onChange` fires. This is the test the manual-cache alternative was feared to fail, and
  the most important one here.
- Run these per [verification.md](../../verification.md) § App-target tests, and check the "Test run with N tests" line.

## Out of scope

- **`.onScrollGeometryChange` and the hero.** The KNOWN-ISSUES standing rule stands. Don't add scroll observation back as a way
  to test this, and don't restore the collapsing hero.
- **`FetchKeyRequest`, or any new database observation.**
- **Stored or lazy projections inside `TripPlan`.**
- **Memoizing `ItineraryList` itself.** Selection changes and each ETA arrival rerun `TripItineraryView.body`, and each rerun
  builds the list once. That's the contract. `now` is an input, so a key would miss every time. Raise it on the PR if a test
  shows otherwise.
- **Other per-read derivations:** `TripCanvasMapView`, `DayChipBar`, `TripBookingRollup`, Today, and Journey all get the
  snapshot and nothing more. They weren't in the trace. If the gate finds them hitching, that's a new brief from a new trace.
- **Trimming `Idea` or `MapRegion` fetches, or changing any row's look or behavior.**

## Done when

- `TripPlanningModel.plan` returns the stored snapshot, and `buildCount` proves it.
- `StopRow`, `StopRowAccessory`, `StopMenu`, and `StopMenuActions` don't read `model.plan` or call a move check in `body`.
  `TripItineraryView.swift` derives one `ItineraryList` per list, and no `itineraryItems`, `locatedSequenceNumbers`, or
  `overlappingStayIDs` call remains in the itinerary views. The new lint rule is in and passing.
- Every test above is green, and the existing `TripPlan`, `ItineraryAlternatives`, and Today projection tests pass unchanged.
  Editing one of them to fit is a finding to raise on the PR.
- `scripts/check-drift.sh` passes, and the app-target tests ran headless. Compile only, with no simulator walkthrough.
- The closeout updates the **Cause** paragraph in KNOWN-ISSUES to say the per-row rebuilds are gone and the modifier's freeze
  is still unexplained. The rule itself doesn't change.
- The closeout carries this gate, word for word, with `--gate`:

  > **Plan snapshot (`plan-snapshot`).** On the iPad, TestFlight build, on Eastern France and then Bavaria/Dolemites. Flick the
  > whole-trip itinerary from top to bottom and back: it keeps moving and never locks up. Tap a stay label, a day chip, then All:
  > no freeze, and the list lands where it should. Rows still show what they did: sequence numbers, connectors filling in their
  > times, the "N options" title and controls on an alternatives stop, and the warning triangle on a home base that overlaps
  > another stay. Under a day lens, drag an Anytime stop to a new position and it stays there. From a stop's menu, use Move Earlier
  > and Move Later: they're disabled on the first and last Anytime stop and update after a move, and VoiceOver's actions on the
  > row agree. Rename a stop's idea: the itinerary shows the new name without reopening. Edit a stop on Wendy's phone: it arrives
  > without reopening. Change the trip's length: days appear or go. If either trip still hitches, record a Time Profiler trace on
  > a Dev build and send it to the architect. Don't add scroll tracking to test it.
