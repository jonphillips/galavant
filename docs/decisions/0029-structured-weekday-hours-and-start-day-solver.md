# ADR-0029: Structured weekday hours on `Idea` + the start-day solver

*Status: accepted — 2026-07-02 (implemented on `feat/m6f-structured-hours-solver`).
Closes the "capture gap — dedicated session" flag in
`docs/trip-time-model.md` §3. Two coupled parts: **C1** the structured-hours model +
capture, **C2** the pure solver over it. Independent of discovery quality (ADR-0018) and
of the two-device beta — the high-confidence M6e slice.*

## Context

The **start-day solver** has been the documented payoff of the day-relative itinerary
since the recovered requirements (`docs/trip-time-model.md` §3). Because the itinerary
keys off **day number** (§2) and `Trip.startDate` is optional/late-binding (§1), the
start weekday is a **free variable**: slide it and check whether key stops are *open* on
the weekday their day number lands on. Canonical case — the destination restaurant you
reach on day 6 is **closed Mondays**: which start dates keep day 6 off a Monday?

The blocker is data shape. Today `Idea.openingHours` is a **free-form string**, captured
three ways — the schema.org `openingHours` scrape (M4a), the browser tap-to-fill chip
(ADR-0025/hours rung), and the M6c `HoursExtractor` LLM fallback (ADR-0016). The solver
needs **open/closed per weekday**, so a representation step is missing between capture and
the solver. `trip-time-model.md` §3 flagged exactly this and deferred it to "a dedicated
session." **This ADR is that session.**

Confirmed direction (Jon, 2026-07-02): **the LLM structures the hours at capture time,
with a hand-editable structured field as the override; the free-form string stays the
captured source of truth.** A follow-on call the same day: the model treats **meal
service** (lunch / dinner) as a first-class question, not just open/closed — restaurants
run **split service**, and the real planning question is "open *for the meal we want*"
(§1, §4). What already exists to build on: `HoursExtractor` (on-device
`ModelClient` extract-only, GalavantPlaces), the `hoursProvenance` / `hoursVerifiedAt`
staleness stamps (M6c), the `Schedule` facade + `TripIdea.itinerary(_:lengthInDays:)` →
`[ItineraryDay]` and `Trip.date(forDay:)` (M3c).

## Decision

### 1. The representation — a `WeeklyHours` value type (GalavantSchema, pure)

`WeeklyHours` = seven `DayHours`, one per `Weekday` (Mon…Sun). A day's openness is a list
of **service periods** — "sittings" — each optionally labeled with a meal and optionally
carrying a clock interval:

```swift
struct ServicePeriod {          // one sitting
  var meal: Meal?               // .breakfast / .lunch / .dinner / .lateNight
  var interval: OpenInterval?   // minute-of-day pair, when known
}                               // at least one of meal / interval is present
enum DayHours { case closed, unknown, open([ServicePeriod]) }
```

- **Split lunch/dinner service falls straight out of the list**
  (`Tue → .open([12:00–14:00, 19:00–22:00])`); the meal label makes "open for dinner" a
  first-class question rather than a clock range you re-derive each time.
- **Faithful to every capture shape.** schema.org intervals arrive `meal: nil` (meal
  **derived on read**); a guide's *"dinner only"* arrives `meal: .dinner, interval: nil`
  (no fabricated clock); a source stating both fills both.
- `serves(_ meal:) -> Bool?` is a pure read — the label if present, else the interval
  overlapped against a (v1 fixed, later locale-aware) meal window; `.unknown → nil`.
- **`.unknown` is distinct from `.closed`.** A page silent on Tuesday is not *asserting*
  closed; the solver must treat unknown as "no conflict asserted," never a false alarm.
- Clock intervals stay a **bonus** for the plain open/closed check and later reuse
  ("opens in N days" / booking windows).

Pure, `Codable`, no I/O — a functional-core value type. `Meal` is extensible; v1's solver
drives on `.lunch` / `.dinner`.

### 2. Storage — one encoded column, additive (GalavantSchema)

`Idea` keeps `openingHours: String?` **unchanged** (the faithful captured source of
truth) and gains **one additive `structuredHours` column** holding a `Codable`-encoded
`WeeklyHours` (CloudKit-legal — it's a string). Staleness reuses the existing
`hoursProvenance` / `hoursVerifiedAt`; `hoursProvenance` gains a **`.manual`** value that
enrichment must respect (below). Migration + SyncEngine registration, per ADR-0009's
additive-column pattern.

**Why one encoded column, not seven flat ones.** The `Certainty` / `Schedule` facades use
flat columns *because they're queried and sorted in SQL*. Hours are **never** queried in
SQL — they're loaded and handed to a pure solver — so that discipline doesn't apply; one
encoded column behind the `WeeklyHours` facade is simpler and equally CloudKit-legal.

### 3. Structuring at capture — extend `HoursExtractor` (GalavantPlaces)

Deterministic-first, mirroring the existing hours ladder:

1. **Deterministic parse** of the schema.org `openingHours` machine format
   (`"Mo-Fr 10:00-18:00"`) / microdata → `WeeklyHours`, a pure parser (GalavantCapture or
   GalavantSchema). Intervals arrive `meal: nil` — meals derive on read. No model call
   when the markup is already structured.
2. **LLM fallback** — `HoursExtractor` learns to emit `WeeklyHours` (guided generation /
   strict JSON) from the free-form string / `bodyText` when there's no structured markup.
   It may set a `ServicePeriod.meal` **directly when the prose states it** ("dinner only",
   "no lunch Mondays") — the case pure derivation can't reach. On-device tier, extract-only,
   `testValue → nil`. Runs in **`PlaceEnricher`** (the
   app-side second hop, M4g) — *not* the memory-tight share extension, exactly where the
   current string fallback already runs.

Structured hours inherit the `hoursProvenance` (`.official` / `.unverified`) +
`hoursVerifiedAt` stamp. Enrichment is **fill-blanks-only** and **never clobbers a
`.manual` override** (same discipline as the M4h cover-image override + the `enrichedAt`
once-gate).

### 4. The solver — `StartDaySolver` (GalavantSchema, pure — the payoff)

A pure function over (itinerary day numbers × each key stop's `WeeklyHours` × a candidate
start weekday) → conflicts. For each of the 7 candidate start weekdays, map each
`dayNumber → weekday` and check every keyed stop against its `WeeklyHours` on that weekday.

**The check is meal-aware, not just open/closed.** A stop's schedule implies an
**intended meal**: a *food* stop scheduled `.timed` or `.daypart` maps its time to a meal
(`.daypart(.evening)` / an evening clock → dinner; midday → lunch; morning → breakfast).
Then:

- **intended meal present** → conflict when `serves(meal)` is `false` that weekday (open,
  but not for *that* meal — the "does lunch Mondays, we wanted dinner" case);
- **no intended meal** (bare `.day`, or a non-food stop) → fall back to plain open/closed
  (`.closed` conflicts; `.open` / `.unknown` don't).

A conflict is `HoursConflict(stop, dayNumber, weekday, reason)` with `reason` =
`.closed` or `.notServingMeal(Meal)`. Returns per-start-weekday conflict sets so the UI
ranks starts ("Start Tue: 0 conflicts · Start Mon: Day 6 → Restaurant X **no dinner**").

**Meal-service and scheduling stay separate concepts.** `DayPart` / `Schedule` remain the
*scheduling* primitive; meal-service belongs to a food idea's *hours*. The solver is the
**only** bridge (an evening food stop ⇒ check dinner service) — a museum scheduled Evening
is never "dinner."

**"Key" stops (v1):** all *scheduled* stops that carry structured hours; weighting toward
must-do (shortlist rank / interest) is a later refinement. No AI, no MapKit, no I/O — a
STYLE.md functional-core showcase, trivially testable.

### 5. Hand-editable override + solver UI (app, later slice — M5 band)

- **Structured-hours editor** in the Idea form: a 7-row weekday grid
  (closed / open + interval pickers). A manual edit stamps `hoursProvenance = .manual`,
  which **wins over re-enrichment**; the free-form string stays displayed as captured.
- **Start-day solver panel** on a dated-or-datable trip: 7 weekday options (or a start-
  date range), each showing its conflict count + the offending stops. **Advisory** — it
  never moves a stop or changes the start; it *shows* which starts are clean. Per the
  staleness rule, each conflict shows the stop's `hoursVerifiedAt` ("closed Mondays *as of
  when we saved it*"). Stops with `.unknown` hours simply don't constrain — the panel
  degrades gracefully before hours coverage is complete.

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **Seven flat weekday columns** (Certainty/Schedule style) | Rejected. Those are flat *because they're queried/sorted in SQL*; hours are only loaded and fed to a pure solver. One encoded `WeeklyHours` column behind a facade is simpler, equally CloudKit-legal. |
| **Discard the free-form string once structured** | Rejected. The string is the faithful captured source of truth; structuring can be lossy/wrong. Keep both (the ADR-0026 description-faithfulness instinct). |
| **Structure on-demand at solve time** (parse the string each solve) | Rejected. Puts a non-deterministic LLM inside a hot pure function. Structure **once** at capture, cache, allow hand-edit. |
| **Require full clock hours** | Rejected. Weekday-level open/closed is all the solver needs; intervals are an optional bonus, not a gate on coverage. |
| **`.unknown` ≡ `.closed`** | Rejected. A page silent on a weekday isn't asserting closed; conflating them manufactures false "closed" alarms. Unknown asserts no conflict. |
| **Meal-service derived from clock intervals only** | Rejected. Sources state meals *without* clocks ("dinner only"); derivation alone would fabricate hours we don't have. `ServicePeriod{meal?, interval?}` stores whichever the source gives and derives the rest on read. |
| **Meal-service merged into the scheduling primitive** (`DayPart`) | Rejected. Meal-service belongs to a food idea's *hours*, not the schedule — merging would make a museum's Evening stop "dinner." Keep them separate; the solver is the only bridge. |
| **LLM-structured at capture + one encoded column + pure solver (chosen)** | Reuses the M6c hours ladder + M4g enricher, keeps the solver a testable AI-free core, and delivers the long-documented start-day payoff without a schema-shape gamble. |

## Relationship to prior decisions

- **`trip-time-model.md` §1–3:** delivers the documented start-day solver and closes the
  §3 "dedicated session" capture-gap flag. Sliding the start weekday re-derives the
  calendar view; it **never** rewrites the day-relative itinerary (§2).
- **ADR-0016 / M6c (hours supplement ladder):** extends `HoursExtractor` to emit
  structured hours, deterministic-first, in `PlaceEnricher`. The string path is unchanged.
- **ADR-0004 (explicit pull):** a pure planning **aid** — advises on start dates, never
  moves stops or pulls anything.
- **ADR-0014 seam / [[galavant-ai-cross-app-seam]]:** the LLM structuring uses
  `ModelClient` (on-device tier) from GalavantPlaces; `WeeklyHours` + `StartDaySolver` are
  pure GalavantSchema — **no AI in the core.**
- **ADR-0009 (additive columns / migration):** `structuredHours` follows the additive
  column + SyncEngine-registration pattern.
- **ADR-0030 (itinerary-aware suggestions):** structured weekday hours let "what could we
  do Tuesday" filter to places actually **open that day** — a downstream quality input.

## Consequences

- **GalavantSchema:** `Weekday` / `Meal` / `ServicePeriod` / `OpenInterval` / `DayHours` /
  `WeeklyHours` value types (with `serves(_:)`); additive `structuredHours` column +
  `hoursProvenance = .manual` on `Idea` + migration + SyncEngine registration; the
  **meal-aware** `StartDaySolver` pure core + tests; a schema.org-tokens → `WeeklyHours`
  parser (may live in GalavantCapture).
- **GalavantPlaces:** `HoursExtractor` emits `WeeklyHours` (on-device guided generation)
  as the LLM fallback; `PlaceEnricher` wires deterministic-first structured hours,
  fill-blanks-only, never clobbering a `.manual` override.
- **App:** a structured-hours editor in the Idea form (manual override wins); a start-day
  solver panel on trips (later slice).
- **No two-device / discovery-quality dependency** — the safe, high-confidence M6e slice;
  a natural first build while the beta lands and the ADR-0018 spike runs in parallel.

## Slices

- **Slice 1 — model + storage:** `WeeklyHours` (incl. `ServicePeriod` / `Meal` +
  `serves(_:)`) + the schema.org-token parser + the additive column/migration;
  deterministic capture path in `PlaceEnricher`; tests.
- **Slice 2 — the meal-aware `StartDaySolver` pure core + tests** (the payoff, no UI —
  cover open/closed **and** intended-meal: lunch-only weekday vs a wanted-dinner stop).
- **Slice 3 — LLM fallback:** `HoursExtractor` emits `WeeklyHours` (on-device), wired into
  `PlaceEnricher`; fixture tests (a free-text-hours page → structured).
- **Slice 4 — the editor:** hand-editable structured hours in the Idea form
  (override-wins).
- **Slice 5 — the solver panel** on trips (M5 band) + docs (flip to accepted,
  ROADMAP/BACKLOG/`trip-time-model.md` §3).
