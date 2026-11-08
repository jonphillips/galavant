# Effort — Filling slots from the guide: put places in the trip without going back to it

**Status:** Ready · **Summary:** Slice 3.3 of [ADR-0053](../decisions/0053-taste-record-and-region-guide.md) (D8). From
the guide, a place can go into an open lunch or dinner slot, join a filled slot as another option, or go on the trip's
shortlist. A hotel can take an open run of nights. Tapping a slot narrows the guide to that slot, where you pick the active
option or take one out. Every write goes through the trip's own operations. No schema, migration, sync, or hand-off change.

**Read first:** ADR-0053 D8; the mockup [`region-guide-trip-lens.html`](../mockups/region-guide-trip-lens.html), frames 1
and 2; ADR-0035 (rings); ADR-0029 (meal-aware hours); the [`guide-trip-lens`](archive/guide-trip-lens.md) brief, whose
`GuideTripLens` this reads.

**Depends on `guide-trip-lens`.** Start from a `main` that has it.

## Today

- `TripIdea.pull(ideaID:into:status:in:)` is idempotent, and re-pulls a declined idea. It does **not** change the status of
  an existing `.considering` row.
- `TripIdea.schedule(_:stopID:in:)` places a stop on a day and sets `.scheduled`.
- `TripIdea.addAlternative(sourceStopID:to:in:)` needs the source `.shortlisted` and the target `.scheduled`. The source
  joins the target's ring, or makes one, **inactive**, with the target's placement copied over.
- `setActiveAlternative(stopID:in:)` picks the active option.
- `unschedule(stopID:in:)` on a ring member **dissolves the whole ring**. There's no operation that takes one option out and
  leaves the others. `markSkipped` and `remove` show how to take one member out and renormalize the rest.
- `TripStay.create(…)` (`TripStayOperations.swift`) is "Stay here": a pool hotel as a stay across `checkInDay…checkOutDay`.
- `Idea.weeklyHours` and `WeeklyHours.serves(_:on:)` answer "open for dinner on Thursday?" with `true`, `false`, or `nil`
  (unknown, so never warn).

## Part 1. The operations (`GalavantSchema`)

```swift
public enum GuideSlotAction: Equatable, Sendable {
  case schedule(day: Int, DayPart)                  // into an open lunch or dinner slot
  case addOption(to: TripIdea.ID)                   // into a filled slot's ring
  case move(stopID: TripIdea.ID, day: Int, DayPart) // a lone stop, to an open slot
  case shortlist                                    // on the trip, no slot
  case stay(nights: ClosedRange<Int>)               // a hotel, for an open run of nights

  public func apply(ideaID: Idea.ID, tripID: Trip.ID, in db: Database) throws
}

extension TripIdea {
  /// Take one option out of its ring and back to the shortlist. The others stay a ring,
  /// renormalized, with a new effective active if this one was active.
  public static func detachAlternative(stopID: TripIdea.ID, in db: Database) throws
}
```

Pinned:

- **`apply` is one write transaction.** Callers wrap it in one `database.write`, and nothing is half-done.
  - **`.schedule`:** `pull`, then raise `.considering` or `.declined` to `.shortlisted` (`setStatus`), then `schedule(.daypart(day, part))`.
  - **`.addOption`:** the same pull and raise, then `addAlternative(source:to:)`. The new option is inactive, so the trip's
    route doesn't change until someone picks it.
  - **`.move`:** `schedule(.daypart(day, part), stopID:)`.
  - **`.shortlist`:** `pull`, then raise to `.shortlisted`.
  - **`.stay`:** `TripStay.create` with `checkInDay = nights.lowerBound` and `checkOutDay = nights.upperBound + 1`.
- **An open slot gets `.daypart`, never a clock time.** A filled slot's options copy the target's placement, timed or not,
  because that's what `addAlternative` does.
- **`detachAlternative`:** the member becomes `.shortlisted`, with its placement cleared and its ring id and active flag
  reset, as `unschedule` does for a lone stop. The rest renormalize the way `markSkipped` leaves them, and a ring left with
  one member stops being a ring. Reuse `normalizeAlternativeMembers`. Don't copy it.

## Part 2. The Add to Trip menu, as a value (`GalavantSchema`)

```swift
public struct GuideSlotMenu: Equatable, Sendable {
  public struct Row: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String          // "Wed lunch", "Day 5 dinner", "Nights 7–8", "Trip shortlist"
    public var detail: String         // "Open slot", "Add as an option to Ca' del Larice · 2 options", "Closed Thursdays"
    public var action: GuideSlotAction?   // nil = shown, but disabled
    public var isCurrent: Bool        // the idea is already here (shown checked)
  }
  public var sections: [[Row]]        // one per region day on Dining; one for nights on Hotels; shortlist last

  public init(lens: GuideTripLens, idea: Idea, entries: [TripIdea], stays: [TripStay], calendar: Calendar)
}
```

Pinned, as a table the tests follow:

| The idea, on this trip | An open slot | A filled slot | Shortlist row |
| --- | --- | --- | --- |
| Not on it, or considering/shortlisted/declined | `.schedule` | `.addOption(to:)` the slot's first stop | `.shortlist`, or checked if already shortlisted |
| A lone scheduled stop in a meal slot | `.move` (its own slot is checked) | disabled: "Already on Tue dinner" | disabled |
| A ring member | disabled: "One of the options for Wed dinner" (its own slot is checked) | same | disabled |

- **Closed is a reason, not a hidden row.** On a dated trip, when `weeklyHours?.serves(meal, on: weekday) == false`, the row
  is disabled with "Closed Thursdays" (the day is closed) or "No lunch on Tuesdays" (open, but not for that meal). `nil` is
  allowed with no warning. On an undated trip, nothing is checked for closures, because there are no weekdays.
- **Dining menus** come from Dining guides and **Hotels menus** from Hotels guides. A Hotels menu lists each `.open` night run
  as "Stay here · Nights 7–8" (`.stay`). An idea that's already a stay shows that run checked and no other actions. Hotels
  have no shortlist row, because a stay opts out of the shortlist lifecycle.
- **"Eat here again"** (`repeatScheduled`, a second occurrence) is not offered. A scheduled idea moves or stays put.

## Part 3. The screen (app target)

- **Add to Trip:** when the guide has a lens, the dossier it opens gets a bottom bar with an **Add to Trip** `Menu`, built from
  `GuideSlotMenu` (mockup frame 1). Rows show title and detail, disabled rows show their reason, and the current slot is
  checked. Choosing a row runs `apply` and gives success haptic feedback (`.sensoryFeedback(.success, …)`). The strip and
  badges update by observation, so nothing is refreshed by hand.
  - **Hosting:** `IdeaMapSplitView` takes an optional `dossierAccessory` view (default empty), placed with
    `.safeAreaInset(edge: .bottom)` on the panel. The compact sheet does the same. `IdeaDetailView` doesn't learn about trips.
- **Slot focus (mockup frame 2):** tapping a cell selects that slot, replacing `guide-trip-lens`'s tap-to-open-dossier.
  - **A filled slot:** a banner ("Showing options for Wed dinner", ×), and the card list is replaced by that slot's stops in
    ring order (`canonicalAlternativeOrder`). The active one is tagged **Active**. The others show **Make active**
    (`setActiveAlternative`) and **Take out** (`detachAlternative`). A lone stop shows **Take out** (`unschedule`). Tapping a
    row opens its dossier. A freeform option shows as a plain row.
  - **An open slot:** the same banner ("Wed lunch is open"), and the cards narrow to those not known to be closed for that
    meal that day. So "who can do Wednesday lunch?" is one tap.
  - **The map** shows only the focused slot's places while focused. × or tapping the cell again clears the focus.
- **Distance from the night's hotel:** in slot focus, each located option shows "2.4 km from Albergo Pradel". That's the
  straight-line distance to the stay that owns that day (`stayID(owningDay:)`), formatted for the locale. There's no travel
  estimate and no network. It's omitted when either end isn't located. Make it a pure function and test it.
- **Drag onto a cell (iPad only):** cards are `.draggable` with the idea's id. Each cell is a `.dropDestination` that runs the
  action the menu would offer for that cell, and refuses drops where that row is disabled, with the targeted cell
  highlighted. If dragging out of the `List` fights scrolling or selection, ship without it and say so on the PR. The menu is
  the path that has to work.

## Tests

**Package:**

- `apply`, over the in-memory database, for each case:
  - `.schedule` puts a new idea in the slot as `.daypart`.
  - The same works for an idea that was `.considering` or `.declined`.
  - `.addOption` onto a lone stop makes a ring of 2 with the original still active.
  - `.addOption` onto a ring of 2 makes a ring of 3 with the new one inactive.
  - `.move` puts the stop in the new slot.
  - `.shortlist` leaves the idea shortlisted.
  - `.stay(7…8)` creates a stay with check-in 7 and check-out 9.
- `detachAlternative`: 3 to 2. 2 to no ring. Detaching the active one leaves exactly one effective active.
- `GuideSlotMenu`, as the table above, row by row. Closed on a dated trip for the whole day and for the meal only. Unknown
  hours. An undated trip shows no closures. Hotel runs, and an idea that's already a stay.
- Distance: a known pair of coordinates, a day with no stay, and an unlocated idea.

**App target:** choosing a menu row in `RegionGuideModel` writes through `apply`, and the lens shows the new state after a
load. In slot focus, Make active and Take out change the lens.

## Out of scope

- Candidate hotels for the same nights (ADR-0053 OQ5): a synced-schema decision that goes back to Jon.
- Choosing a time, reordering a ring, second occurrences, and editing bookings from the guide.
- Chat in the guide, and ADR-0053 OQ1.

## Done when

- From a guide dossier, Add to Trip can put a place in an open slot, add it as an option, move a lone stop, shortlist it, or
  give a hotel an open run of nights. Disabled rows say why.
- Slot focus lists a slot's options, makes one active, and takes one out without dissolving the rest.
- Every test above is green, and the plan, alternatives, stay, guide, and lens tests pass unchanged.
- `scripts/check-drift.sh` passes, and the app-target tests ran headless and passed (`verification.md`). Compile only, with
  no simulator walkthrough.
- The closeout carries this gate, word for word, with `--gate`:

  > **Filling slots from the guide (`guide-slot-filling`).** On the iPad, TestFlight build, on a real upcoming trip. In the
  > Guide's Dining strip, open a restaurant and Add to Trip: an open lunch. The cell fills, and the trip's itinerary shows it
  > on that day. Add a second restaurant to that same slot: it reads "2 options", and the itinerary's route doesn't change.
  > Tap the cell: both options, one Active. Make the other active, then take one out: the slot keeps the rest. Find a place
  > closed one of your days: that row says why. Drag a card onto an open dinner. On Hotels, give an open night a hotel with
  > Stay here. Then on the iPhone, add one place from the sheet. Open the trip and check everything you did is there. **Then
  > judge:** Did you plan meals here without going back to the trip? What did you still have to go back for? Do you want
  > candidate hotels (ADR-0053 OQ5)?
