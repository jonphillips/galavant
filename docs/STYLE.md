# Coding style — the Point-Free Way, without TCA

*The house style. New code pattern-matches this; once M0 lands, the Idea feature
is the living exemplar and beats anything written here.*

## 1. Value types by default

Domain models are structs. `@Table struct Idea` — SQLiteData was chosen partly
because its records are plain structs (this is the anti-SwiftData decision:
no `@Model` classes, no reference-semantics object graph).

Classes appear only where a framework demands reference semantics:
- `@Observable final class` feature models (the observation boundary)
- Framework wrappers that are inherently reference-y (WKWebView store)

Nothing else. If a class exists for any other reason, it's a code smell.

## 2. Functional core, observable shell

Domain logic is pure functions on value types: schedule math, itinerary
derivation, match scoring, filtering, token generation. No I/O, no globals, no
clock access inside them — inputs in, value out.

- House exemplar of the good pattern: V1's `PlaceSearchStrategy` (pure static
  functions: tokenize, score, rank — trivially testable).
- Feature models orchestrate: hold state, call the pure core, run effects
  through dependencies.

## 3. Make impossible states unrepresentable

Enums with associated values over flag combinations. The bar is V2's `Schedule`
enum — `unknown / approximated(day, daypart) / timed / exact` — which replaced
five interacting V1 fields (`dateSelected`, `scheduled`, `timeGranularity`,
`approximatedDayNumber`, `daypart`). When two booleans can describe a state
that can't happen, reach for an enum. CasePaths where ergonomics demand.

Navigation state is the same principle: one optional `Destination` enum per
feature model (swift-navigation), not N boolean `isShowingX` flags
(V1's sheet-manager zoo is the anti-pattern).

## 4. Dependencies, not singletons

`@Dependency` (swift-dependencies) for clock, date, UUID, database, network,
location. **No `AppCurrent` / `UniverseCurrent` globals this time** — V1's
World-pattern global service graph is explicitly retired. Tests override
dependencies; nothing reaches out to shared mutable state.

## 5. Errors are values; issues are reported

- Throw/Result for expected failures; no silent `catch { print(...) }`
  (a V1 habit to break — see `case .failure: print("Could not store boards")`).
- `reportIssue` / `withErrorReporting` (IssueReporting) for
  should-never-happen states — loud in DEBUG and tests, quiet in release.

## 6. Testing

- swift-testing (`@Test`, `#expect`) + CustomDump (`expectNoDifference`) for
  value assertions.
- Determinism via controlled dependencies (clock/UUID/date), not sleeps.
- The pure functional core gets the densest coverage; feature models get
  behavioral tests; snapshot tests where UI regressions hurt.

## 7. Concurrency

- async/await + structured concurrency throughout. `DispatchQueue` and
  `asyncAfter` are banned (V1 habit).
- Feature models are `@MainActor`.
- The swift-concurrency-pro skill reviews concurrency-heavy changes.

## 8. Mechanics

- 2-space indentation (house style since V1).
- Naming per ADR-0006; spell-check anything that lands in the schema.
- Reusable, app-agnostic code goes in the local SPM package with its own tests.
- Dependencies stay minimal; every package needs a reason (ADR-0002).
