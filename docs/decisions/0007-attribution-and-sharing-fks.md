# ADR-0007: Per-planner attribution, and the single-FK sharing rule

*Status: accepted — 2026-06-12*

## Decision

### Planner identity
- A **`Planner`** record (`id`, `displayName`) represents a person who plans.
  Not an account — there is still no auth (ADR-0001). Just a synced row.
- Each device knows which planner it *is* via a local setting
  **`currentPlannerID`** (e.g. `@Shared(.appStorage)`), set on first run
  ("What should we call you?") and again on the second device after it accepts
  the travel-party share.
- Planner subsumes the `addedBy` attribution foreshadowed in ADR-0003: every
  authored thing (ratings, notes, captured ideas) references a `Planner`.

### Ratings / opinions
- A **`IdeaInterest`** record carries: one real FK → `Idea`, a loose `plannerID`
  UUID (NOT a SQL foreign key), the interest level, and an optional note.
- His-and-hers (ADR-0006 resolved Q1) falls out naturally: one `IdeaInterest` row
  per (idea, planner). N planners for free — opening to a third is a new row,
  no migration.
- **Not** two fixed columns on `Idea` (`myRating`/`spouseRating`): in a shared
  DB that creates a "which column does this device write?" ambiguity and
  hard-caps at two people.
- **Not** a two-FK join table either — see the sharing rule below.

## The single-FK sharing rule (governs ALL future relationships)

SQLiteData's CloudKit sharing carries an associated record along with its
shared root **only if the record has a single foreign key** (and isn't in
`privateTables`). The root itself has none. Therefore, in V3's schema:

- The shareable graph is a **tree rooted at `TravelParty`**, each node holding
  exactly one real FK to its parent: `TravelParty ← Idea ← IdeaInterest`, etc.
- Any "second relationship" (IdeaInterest→Planner, Idea→MapRegion, TripIdea→Idea
  beyond its primary parent) is modeled as a **loose UUID column**, not a SQL
  foreign key. Referential integrity there is by-convention; acceptable because
  the referenced rows (Planners, MapRegions) also sync and are tiny.
- When a future entity seems to need two parents, ask which one it rides the
  share through; that one is the FK, the other is a loose UUID.

This rule is why join-table patterns from V1/V2 (and ordinary relational
instinct) must be adapted, not copied, when they touch synced/shared data.

## Consequences

- `currentPlannerID` is device-local and does NOT sync (it means something
  different on each device). Everything else syncs.
- Display of "his and hers" is a query joining `Idea` to its `IdeaInterest`s by the
  real FK, then labeling each by looking up `plannerID` → `Planner.displayName`.
- The start-day solver (trip-time-model.md) filters on `IdeaInterest.level` for the
  current planner (or max across planners for "anyone marked must-do").
- M2 gains: `Planner` table, `currentPlannerID` setting + first-run capture,
  `IdeaInterest` table and the his/hers rating UI.
