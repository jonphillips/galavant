# Handoff: Today — preview any trip day at home

Status: Dispatched
Summary: Turn the on-the-ground "Today" iPhone surface into something you can walk
through day-by-day before (or after) a trip, instead of it locking to the live
clock and showing "This trip is not active today".

Implements: ADR-0038 (Journey/Today projections + weather) — this is an additive
surface change, no schema, no new persisted concepts, no ADR revision needed.

---

## Why (one paragraph)

`TodayView` renders `TodayProjection.resolve(…, now:)`, and `resolve` returns
`nil` the moment `now` isn't inside the trip's dated span — that `nil` is the
"This trip is not active today" screen. But `resolve` is already a **pure
function of `now`**: feed it the start of any trip day and it produces a correct,
complete projection for that day. So "let me review each day at home" is not a new
feature in the core — it's letting the view choose which instant to render.
Weather simply falls away for non-live days, which is already the projection's
designed primary (no-weather) state.

**The decision (from Jon): preview renders the _start of day_** — you see the
whole day's plan as it looks first thing in the morning (everything upcoming,
nothing collapsed into "earlier today"). That's the right frame for "am I happy
with this day?".

---

## Shared context (read first)

Repo: galavant (V3) at `~/code/galavant/galavant`. Household iOS app, SwiftUI,
SQLiteData+CloudKit, no server, Point-Free style **without TCA**. Read `AGENTS.md`
+ `CLAUDE.md` first. Conventions that bite:

- **Branch + PR workflow:** never push to `main`. Work on a feature branch off
  `main` and open a PR. **No git worktrees** in this repo — a plain checkout on
  your branch is correct.
- **XcodeGen-managed project:** `project.yml` is the source of truth,
  `project.pbxproj` is generated AND tracked. `xcodegen generate` is needed **only
  when you add/remove a file in the _app_ target**. **This change adds no new
  files** — you edit two existing Swift files and one existing test file — so **no
  `xcodegen generate` and no pbxproj change are required.** Do not create new
  files.
- App builds with `-skipMacroValidation` (macro trust may need re-approval in
  Xcode). Build/run via `xcodebuild`/Xcode, not `swift test` — `swift test` aborts
  here on unrelated FoundationModels-linked targets. To run the schema unit tests
  see "Testing" below; none of this change touches FoundationModels.
- **Today is an iPhone-only (compact) surface.** The entry button is gated on
  `!usesColumn` in `TripPlanningView.swift:87`, so it does **not** appear on iPad.
  Review this on an **iPhone simulator** (the usual iPad Pro review sim will never
  show the Today button). Leave the iPhone-only gating as-is; iPad access is out of
  scope.
- Match the surrounding comment density/idiom. No version suffixes in identifiers
  (ADR-0006). Keep pure/derivable logic in the functional core and tested.

### The three files you touch

- `GalavantLibrary/Sources/GalavantSchema/TodayProjection.swift` — add two tiny
  pure public helpers (day ↔ start-of-day).
- `Galavant/Today/TodayView.swift` — all the wiring (day selection, render
  instant, stepper, preview badge, weather gating).
- `GalavantLibrary/Tests/GalavantSchemaTests/TodayProjectionTests.swift` — add
  tests for the two helpers + a start-of-day projection test.

`Galavant/Today/TodayModel.swift` is **unchanged** — its `now` remains the live
clock; the view chooses whether to render that or a previewed start-of-day.

---

## Phase 1 — Pure core: two calendar helpers

**Goal:** give the view one authoritative place for "which trip day is `now`?" and
"what instant is the start of day N?", so the view never re-implements the
projection's calendar math (which would drift).

**Context:** `TodayProjection` already has a **private** `dayNumber(for:tripStartDate:calendar:)`
(`TodayProjection.swift:196`) and a private free func `dayStart(dayNumber:tripStartDate:calendar:)`
(`TodayProjection.swift:413`). Reuse the private day-number function; add public
wrappers with clear, non-colliding names. `tripPlan.lengthInDays`
(`TripPlan.swift:111`) is the day upper bound.

**Changes** — add to `TodayProjection` (e.g. just after `resolve(…)`, near
`TodayProjection.swift:129`):

```swift
/// The 1-based trip day that `now` falls on, or `nil` when `now` is outside the
/// trip's dated span. The Today surface uses this so live-day detection and the
/// projection agree on the same calendar math.
public static func tripDay(
  containing now: Date, tripStartDate: Date, in tripPlan: TripPlan
) -> Int? {
  guard let day = dayNumber(for: now, tripStartDate: tripStartDate, calendar: .current),
    day <= tripPlan.lengthInDays
  else { return nil }
  return day
}

/// The start of the calendar day for a 1-based trip day, or `nil` if the day is
/// out of range. This is the instant Today renders when previewing a day that is
/// not the live day.
public static func startOfTripDay(_ dayNumber: Int, tripStartDate: Date) -> Date? {
  guard dayNumber >= 1 else { return nil }
  let calendar = Calendar.current
  guard let date = calendar.date(byAdding: .day, value: dayNumber - 1, to: tripStartDate)
  else { return nil }
  return calendar.startOfDay(for: date)
}
```

Do **not** refactor the existing private `dayNumber`/`dayStart` — leave them as-is
to keep the blast radius minimal.

**Acceptance:** package compiles; both helpers pure (no side effects, no I/O).

---

## Phase 2 — View: choose the render instant + day selection

All in `Galavant/Today/TodayView.swift`. The struct currently holds
`let planningModel`, `@Environment(\.dismiss)`, `@State private var model`, and a
`leaveByBuffer` constant.

### 2a. Add day-selection state + derived properties

```swift
/// The day the user has stepped to. `nil` means "follow the live day".
@State private var selectedDay: Int?

private var tripStartDate: Date? { planningModel.trip?.startDate }
private var dayCount: Int { planningModel.plan.lengthInDays }

/// The trip day the real clock is on, or `nil` when the trip isn't underway.
private var liveDay: Int? {
  guard let tripStartDate else { return nil }
  return TodayProjection.tripDay(
    containing: model.now, tripStartDate: tripStartDate, in: planningModel.plan)
}

/// The day currently shown: an explicit selection, else the live day, else day 1.
private var currentDay: Int? {
  selectedDay ?? liveDay ?? (dayCount >= 1 ? 1 : nil)
}

/// We are previewing whenever the shown day isn't the live day (including any day
/// at all when the trip isn't underway).
private var isPreviewing: Bool {
  guard let currentDay else { return false }
  return currentDay != liveDay
}

/// The instant to render: the live clock when live, otherwise the start of the
/// previewed day (Jon's decision — a morning-of view of the whole day).
private var renderNow: Date {
  guard isPreviewing, let currentDay, let tripStartDate,
    let start = TodayProjection.startOfTripDay(currentDay, tripStartDate: tripStartDate)
  else { return model.now }
  return start
}

/// Weather is a live-only affordance; a previewed day requests none (this also
/// avoids pointless WeatherKit calls for past/far-future days).
private var activeWeatherAnchor: WeatherAnchor? {
  isPreviewing ? nil : projection?.next?.weatherAnchor
}

private var showsDayStepper: Bool { tripStartDate != nil && dayCount >= 1 }

private func step(_ delta: Int) {
  let current = currentDay ?? 1
  selectedDay = min(max(1, current + delta), dayCount)
}
```

### 2b. Point `projection` and `nextConnector` at `renderNow`

In `projection` (`TodayView.swift:17-26`) change the one argument
`now: model.now` → `now: renderNow`.

In `nextConnector` (`TodayView.swift:31-49`) change its `now: model.now`
(currently `TodayView.swift:41`) → `now: renderNow`, so "upcoming" selection and
the Maps connector match the rendered day.

### 2c. Gate weather on the previewing state

Replace the weather task (`TodayView.swift:78-80`):

```swift
.task(id: activeWeatherAnchor) {
  await model.loadWeather(for: activeWeatherAnchor)
}
```

`model.loadWeather(nil)` already clears the displayed forecast, so switching into
preview drops weather cleanly and switching back to the live day reloads it. No
`TodayModel` change needed.

### 2d. Empty states — remove "not active today"

With a start date and `dayCount >= 1`, `projection` now always resolves (to a live
or previewed day), so the `else if let tripStartDate` branch that renders
**"This trip is not active today"** (`TodayView.swift:56-61`) is dead — **remove
it**. Keep the no-start-date branch, and add a no-days branch. The `body`'s
`Group` becomes:

```swift
if let projection {
  today(projection)
} else if tripStartDate == nil {
  ContentUnavailableView(
    "Today is not available",
    systemImage: "calendar.badge.clock",
    description: Text("Set this trip’s start date before using its Today view."))
} else {
  // Has a start date but no itinerary days yet.
  ContentUnavailableView(
    "No days planned yet",
    systemImage: "calendar.badge.clock",
    description: Text("Add itinerary days to preview this trip’s Today view."))
}
```

### 2e. Day stepper + preview badge (toolbar)

Extend the existing `.toolbar` (`TodayView.swift:71-75`) — keep the `Done` item,
add a bottom bar when `showsDayStepper`:

```swift
.toolbar {
  ToolbarItem(placement: .topBarLeading) {
    Button("Done") { dismiss() }
  }
  if showsDayStepper {
    ToolbarItemGroup(placement: .bottomBar) {
      Button { step(-1) } label: { Image(systemName: "chevron.left") }
        .disabled((currentDay ?? 1) <= 1)
      Spacer()
      HStack(spacing: 8) {
        Text("Day \(currentDay ?? 1) of \(dayCount)")
          .font(.subheadline.weight(.semibold))
          .monospacedDigit()
        if isPreviewing {
          Text("PREVIEW")
            .font(.caption2.weight(.bold))
            .tracking(0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(.tint)
        }
      }
      Spacer()
      Button { step(+1) } label: { Image(systemName: "chevron.right") }
        .disabled((currentDay ?? 1) >= dayCount)
    }
  }
}
```

The `PREVIEW` pill is the only cue distinguishing a previewed day from the live
one — it must be present whenever `isPreviewing`. Exact styling is yours; keep the
day header (`TodayDayHeader`) untouched — it already shows the previewed day's
real date and locality.

### 2f. Drop the stray "Now" marker in preview

At `now = start of day`, the itinerary stream inserts a **"Now"** timeline marker
at the very top (rendered by `TodaySupportingViews.swift:61` / `:98`), which is
misleading in a preview. In `today(_:)` (`TodayView.swift:83-112`), filter it out
while previewing before handing the list to `TodayTimeline`. Replace the timeline
block (`TodayView.swift:97-99`):

```swift
let timeline = isPreviewing
  ? projection.remaining.filter {
      if case .item(.nowMarker) = $0 { return false }
      return true
    }
  : projection.remaining
if !timeline.isEmpty {
  TodayTimeline(remaining: timeline)
}
```

Leave the live path (`!isPreviewing`) exactly as it is — the "Now" marker and
"Earlier today" collapse are correct live behaviour.

---

## Behaviour matrix (what the acceptance is)

| Situation | Open shows | Stepper | Weather |
| --- | --- | --- | --- |
| Trip underway (live now on day 3 of 7) | Live day 3, no PREVIEW pill, real "Now"/earlier-today, live ETAs | ‹ Day 3 of 7 ›; stepping off 3 shows PREVIEW; stepping back to 3 resumes live | On (live day only) |
| Trip not started / already ended | Day 1 with PREVIEW pill (no more "not active today") | ‹ Day 1 of N › across all days | Off in preview |
| Start date, zero itinerary days | "No days planned yet" | hidden | — |
| No start date | "Today is not available" | hidden | — |

Preview day content: `NEXT` = the day's first stop; the full timeline with no
"Earlier today" and no "Now" row; `Leave by …` clock times still shown (they're
static and useful); `Tonight`/`Tomorrow` cards as the projection resolves them.

**This surface is now self-verifying on the simulator** — the whole point: you no
longer need the wall clock inside the trip to see Today. Build to an **iPhone**
simulator, open a dated trip, tap the sun/Today button, and step through every
day.

---

## Testing

Add to `GalavantLibrary/Tests/GalavantSchemaTests/TodayProjectionTests.swift`
(reuse its `startDate`, `date(day:hour:)`, `plan`, `stop`, `idea`, `projection`
helpers):

1. **`tripDay(containing:…)`** — a `now` on day 2 returns `2`; a `now` before the
   trip and a `now` past `lengthInDays` both return `nil`.
2. **`startOfTripDay(_:…)`** — day 1 returns `Calendar.current.startOfDay(for: startDate)`;
   day 2 returns the next day's midnight; day 0 returns `nil`.
3. **Start-of-day projection** (the behaviour preview depends on): build a
   multi-stop day-1 plan, `resolve` at `date(day: 1, hour: 0)`, and assert
   `next.item` is the first stop, `remaining.first != .earlierToday(...)`, and the
   `dayContext.dayNumber == 1`. (Compare against the existing
   `nextSelectionAndEarlierTodayCollapse…` test, which checks the live/ midday
   case.)

The view wiring (`selectedDay`/`isPreviewing`/`renderNow`, stepper) is not
unit-tested here — the app target isn't set up for view-model tests and this state
lives in the `View`. It's covered by the pure-core tests above plus the on-device
build/step-through. Do not add an app-target test bundle for this.

**Running the schema tests:** `swift test` aborts in this repo due to unrelated
FoundationModels-linked test targets. Run `GalavantSchemaTests` the way the repo
already does (temporarily excluding the FM-linked test targets, per `AGENTS.md`),
or run them through Xcode's test navigator against the `GalavantSchema` scheme.
Confirm the new tests pass; don't claim green if you only built.

---

## Watch-outs

- Don't touch `TodayModel` — the live clock must keep ticking so returning to the
  live day resumes real-time behaviour.
- Keep the iPhone-only entry gate in `TripPlanningView.swift:87` unchanged.
- `.bottomBar` lives inside the view's own `NavigationStack`
  (`TodayView.swift:52`) within the `fullScreenCover` — that's the right place;
  don't move the toolbar up to the presenting view.
- `planningModel.travelTimes` is populated by `fetchMissingETAs()` before Today
  opens, so preview days get real ETAs; where a leg is still missing, `leaveBy`
  already degrades to `nil`/placeholder — no crash, leave it.
- Don't relabel the `NEXT` hero for preview or add an iPad path — out of scope;
  flag to Jon if you think either is warranted.
- **Known projection bug this surface exposes (fix lives elsewhere):** on a
  *transfer day* (a stay checking out + another checking in), previewing at
  start-of-day drops the check-out row, the between-lodgings drive, and the check-in
  from REMAINING. It's a pre-existing bug in the pure core
  (`TripPlan.nowMarkerIndex` is stop-relative, so `TodayProjection.remainingTimeline`
  slices boundary/connector rows that sort before the marker). Not caused by, and not
  fixed in, this preview slice — see **Phase 0** of `today-execution.md` for the root
  cause, fix requirement, and regression test.
