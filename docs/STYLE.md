# Coding style — Galavant's examples

The style is jon-platform's [`docs/ios/swift-style.md`](../../jon-platform/docs/ios/swift-style.md),
and the rules live there. This file keeps only Galavant's examples and the V1 habits each rule
retires. Section numbers match that doc, so a `STYLE.md §N` citation in code or an ADR means
`swift-style.md §N`.

## 1. Value types by default

`@Table struct Idea`. The only classes are `@Observable` feature models and framework wrappers such
as the WKWebView store.

## 2. Functional core, observable shell

- The pure core here is schedule math, itinerary derivation, match scoring, filtering, and token
  generation. V1's `PlaceSearchStrategy` (tokenize, score, rank) is the model.
- `IdeaFormModel` shows why logic leaves the view. It started as a one-line `upsert` in a draft
  form, picked up party resolution and tag diffing there, and then had to be pulled out.

## 3. Make impossible states unrepresentable

- The `Schedule` value, `unscheduled / day / daypart(DayPart) / timed`, replaces five interacting V1
  fields (`dateSelected`, `scheduled`, `timeGranularity`, `approximatedDayNumber`, `daypart`).
  Calendar dates are derived from the trip's start, never stored. M3c dropped V2's `.exact`.
- V1's sheet-manager zoo is the anti-pattern for one `Destination` enum per feature model.

## 4. Dependencies, not singletons

V1's `AppCurrent` / `UniverseCurrent` World-pattern globals are retired. Location is a dependency
(`LocationClient`, ADR-0046).

## 5. Errors are values; issues are reported

V1's `case .failure: print("Could not store boards")` is the habit to break.

## 8. Mechanics

Naming follows ADR-0006, and dependencies need a reason per ADR-0002.
