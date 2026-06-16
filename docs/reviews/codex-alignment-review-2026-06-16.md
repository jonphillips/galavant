# Codex alignment review - 2026-06-16

Reviewer: Codex

Scope: alignment review against the updated `~/code/jon-platform` guidance, with
Galavant treated both as a working exemplar and as code worth criticizing. This is
not a code-change pass.

## What I checked

- Read the refreshed jon-platform docs:
  - `AGENTS.md`
  - `docs/agent-workflow.md`
  - `docs/ios/swift-style.md`
  - `docs/ios/persistence-and-sync.md`
  - `docs/ios/ui-and-platforms.md`
- Read Galavant's app-local docs:
  - `CLAUDE.md`
  - `docs/PRODUCT.md`
  - `docs/STYLE.md`
  - `docs/ROADMAP.md`
  - `docs/KNOWN-ISSUES.md`
  - key ADRs in `docs/decisions/`
- Inspected schema, operations, models, views, navigation, share extension, and tests.
- Ran verification:
  - `swift test` in `GalavantLibrary`: passed 80 Swift Testing tests with 2 expected
    known-issue reports. One warning remains in `TripTests.swift`.
  - `xcodebuild -project Galavant.xcodeproj -scheme Galavant -destination generic/platform=iOS\ Simulator build`: initially stopped at Xcode macro approval.
  - `xcodebuild -project Galavant.xcodeproj -scheme Galavant -destination generic/platform=iOS\ Simulator -skipMacroValidation build`: succeeded under Xcode 27.0 beta 1.

## What Codex should learn from Galavant

1. Keep app-local docs as the domain ledger, not the house-style ledger.

   `CLAUDE.md` sends agents to jon-platform first, then keeps Galavant-specific
   product/domain decisions locally. That split is good. Yes Chef should do the
   same: cooking/product decisions in the app repo; general Swift, persistence,
   sync, workflow, and tool behavior in jon-platform.

2. Make every milestone a runnable vertical slice.

   Galavant's roadmap is useful because each milestone names the product behavior,
   not just implementation tasks. M0 proved persistence; M1 proved CloudKit; M3
   proved the trip loop. Yes Chef should use the same "done when a real scenario
   works" shape.

3. Use a local package for reusable schema and tested functional core.

   `GalavantLibrary/Sources/GalavantSchema` is the right boundary: table structs,
   pure value projections, and database-as-argument operations live there and are
   covered by Swift Testing. The app target owns UI, feature models, and platform
   glue. This is the pattern to copy before Yes Chef grows UI complexity.

4. Keep views thin, but do not confuse "large view" with "bad view."

   The good boundary is not file size; it is effect ownership. Galavant's views can
   be large layout/composition files, while database writes and multi-step decisions
   live in `@Observable` models and schema operations. This matches jon-platform.

5. Prefer observed reads and pure read models over one-off loading state.

   Galavant's feature models use `@FetchAll` for live data, then derive read models
   such as `TripPlan` from arrays. `TripPlan` is especially worth copying: it joins
   `TripIdea` to `Idea`, drops loose-UUID orphans at read time, and gives the UI a
   single resolved projection. Yes Chef will likely want similar projections for
   recipe lists, meal plans, shopping/cook sessions, or import review flows.

6. Make CloudKit constraints visible in the model, not hidden in comments.

   ADR-0007 plus the code's single-real-FK/loose-UUID shape are a strong exemplar.
   The tree-rooted share model, read-time reconciliation, no unique indexes beyond
   PK, and device-local identity are not optional implementation details. Yes Chef
   should model these up front instead of retrofitting them.

7. Treat iPad as a first-class planning surface.

   Galavant's split between an iPhone bottom sheet and an iPad side column is the
   kind of product-shaped platform adaptation jon-platform asks for. The important
   lesson is not "always use this layout"; it is to decide which device is primary
   for each phase and design the surface around that phase.

8. Record beta problems in `KNOWN-ISSUES.md` with dates, hypotheses, fallback
   plans, and code links.

   The iOS 27 beta notes are concrete enough to stop future agents from repeatedly
   "fixing" upstream problems. Yes Chef should use the same pattern for SDK beta
   issues.

## Suggestions for Claude

### P1: Swipe delete can delete the wrong idea under filters or alternate sort

`IdeasScreen` renders `model.filteredIdeas`, so `.onDelete` offsets are offsets into
that displayed collection:

- `Galavant/Ideas/IdeasScreen.swift:269`
- `Galavant/Ideas/IdeasScreen.swift:271`
- `Galavant/Ideas/IdeasScreen.swift:282`

But `IdeasListModel.deleteIdeas(at:)` maps those offsets through the unfiltered,
name-ordered `ideas` array:

- `Galavant/Ideas/IdeasListModel.swift:387`
- `Galavant/Ideas/IdeasListModel.swift:388`

That means deleting while a region/tag/kind/visited/match filter is active, or while
`matchesFirst` sort changes ordering, can remove a different row than the one swiped.

Suggested fix: mirror `TripsListModel.deleteTrips(_:at:)` and pass the displayed
array into the delete method, or compute IDs from `filteredIdeas` inside the model.
Add a focused test or UI test seed where `ideas != filteredIdeas` and verify the
intended row is deleted.

### P1: ADR-0008 is only partially implemented

ADR-0008 says two hard things:

- second-device identity should bind to existing planners and clean/prefer the
  correct shared party over an empty stray party;
- duplicate logical rows such as `(ideaID, plannerID)` must be deduped on read and
  cleaned up because CloudKit cannot rely on unique indexes.

The picker/bind UI exists, which is good:

- `Galavant/Ideas/IdentityView.swift:24`
- `Galavant/Ideas/IdeasListModel.swift:304`
- `Galavant/Ideas/IdeasListModel.swift:312`

But `TravelParty.ensureDefault(in:)` still returns the first party by UUID:

- `GalavantLibrary/Sources/GalavantSchema/TravelParty.swift:22`
- `GalavantLibrary/Sources/GalavantSchema/TravelParty.swift:23`

And planner creation still attaches to whatever `ensureDefault` returns:

- `GalavantLibrary/Sources/GalavantSchema/PoolOperations.swift:6`
- `GalavantLibrary/Sources/GalavantSchema/PoolOperations.swift:7`

For `IdeaInterest`, the writer updates/deletes only one existing row:

- `GalavantLibrary/Sources/GalavantSchema/PoolOperations.swift:29`
- `GalavantLibrary/Sources/GalavantSchema/PoolOperations.swift:32`
- `GalavantLibrary/Sources/GalavantSchema/PoolOperations.swift:34`

Read-side projections do ad hoc "first wins" or no dedup at all:

- `Galavant/Ideas/IdeasListModel.swift:145`
- `Galavant/Ideas/IdeasListModel.swift:146`
- `Galavant/Ideas/IdeasListModel.swift:147`
- `Galavant/Ideas/IdeasListModel.swift:324`
- `Galavant/Trips/TripPlanningModel.swift:226`
- `Galavant/Trips/TripPlanningModel.swift:227`

Suggested fix: add schema-level helpers that deterministically collapse logical
duplicates, such as "lowest UUID wins" or "oldest row wins" if an ordering column is
added. Make all read-model code call the helper rather than rebuilding dictionaries
locally. Add seeded-duplicate tests for `IdeaInterest`, `IdeaTag`, and `TripRegion`
where logical uniqueness matters. For parties, implement the ADR's "prefer shared /
non-empty party and clean empty stray" rule or explicitly move that work to a dated
roadmap item so comments do not imply it is done.

### P2: Some docs lag current code

The code and roadmap now target iOS 27:

- `project.yml:5`
- `docs/ROADMAP.md:43`

But `CLAUDE.md` still says deployment target iOS 26 until a new API earns the bump:

- `CLAUDE.md:53`
- `CLAUDE.md:54`

The schedule model also drifted. Current code deliberately removed V2's `.exact`
case:

- `GalavantLibrary/Sources/GalavantSchema/Schedule.swift:6`
- `GalavantLibrary/Sources/GalavantSchema/Schedule.swift:9`
- `docs/ROADMAP.md:47`

But several docs still describe the V2 schedule as current or exemplar text:

- `docs/PRODUCT.md:23`
- `docs/STYLE.md:51`
- `docs/decisions/0004-pull-based-trip-membership.md:27`
- `docs/ROADMAP.md:86`

Suggested fix: update these to the current V3 vocabulary:
`unscheduled / day / daypart / timed`, with exact calendar dates derived from
`Trip.startDate` plus day number rather than stored on the stop.

### P2: ID creation is not dependency-controlled

The updated jon-platform guidance says UUIDs should be dependency-controlled where
possible. Galavant's schema operations often call `UUID()` directly:

- `GalavantLibrary/Sources/GalavantSchema/TripOperations.swift:20`
- `GalavantLibrary/Sources/GalavantSchema/TripOperations.swift:138`
- `GalavantLibrary/Sources/GalavantSchema/PoolOperations.swift:8`
- `GalavantLibrary/Sources/GalavantSchema/Tag.swift:30`
- `GalavantLibrary/Sources/GalavantSchema/TripRegion.swift:39`
- `GalavantLibrary/Sources/GalavantSchema/IdeaTag.swift:25`

This has not hurt most tests because the tests assert behavior rather than exact
IDs. Still, it is an alignment gap and a copy-paste risk.

Suggested fix going forward: for new operations, either accept IDs as arguments
with sensible defaults supplied by the feature model, or inject UUID generation at
the model boundary with `@Dependency(\.uuid)`. Do not churn working code just to
chase purity, but avoid spreading direct `UUID()` calls into new vertical slices.

### P2: Derived bindings should be standardized

There are a few `Binding(get:set:)` sites:

- `Galavant/Trips/TripPlanningSheets.swift:91`
- `Galavant/Trips/TripPlanningView.swift:87`
- `Galavant/Trips/TripPlanningView.swift:95`
- `Galavant/Ideas/RegionManagerView.swift:45`
- `Galavant/Ideas/TagManagerView.swift:46`

The Point-Free SwiftUI guidance prefers reusable binding derivation helpers on the
value type, and the project already uses `SwiftUINavigation` case bindings in other
spots. This is not urgent, but it is the sort of small local pattern that agents
will copy unless there is a local helper.

Suggested fix: add tiny helpers for optional presentation and destination cases,
or use existing case-binding syntax where it fits. The value is consistency more
than code reduction.

### P2: One-shot model reads should be cancellation-aware

Most reads are observed, which is the right default. A few model `.task` flows do
one-shot reads into model state:

- `Galavant/Ideas/IdeaFormModel.swift:109`
- `Galavant/Ideas/IdeaFormModel.swift:111`
- `Galavant/Trips/TripFormModel.swift:54`
- `Galavant/Trips/TripFormModel.swift:57`

They are in models, not views, and they are wrapped in `withErrorReporting`, so this
is not the old "read in view `.task` into `@State`" bug. The remaining issue is that
view dismissal can surface harmless `CancellationError` as an issue.

Suggested fix: either make these observed projections if they become live data, or
swallow `CancellationError` explicitly around the one-shot read.

### P3: Keep warnings at zero

`swift test` passes, but it emits:

- `GalavantLibrary/Tests/GalavantSchemaTests/TripTests.swift:150`: `var draft` was
  never mutated and should be `let`.

Tiny, but worth fixing. Warnings in tests are still warnings.

### P3: CLI app builds need macro-validation handling

The first Xcode build failed because Xcode wanted macro re-approval for
StructuredQueries macros. The app built cleanly with `-skipMacroValidation`.

Suggested fix: document this command in `CLAUDE.md` or a verification section:

```sh
xcodebuild -project Galavant.xcodeproj -scheme Galavant -destination generic/platform=iOS\ Simulator -skipMacroValidation build
```

This should not replace human approval in Xcode, but it keeps agent CLI verification
from stopping before app code compiles.

### P3: The share extension is intentionally still a stub

`GalavantShare/ShareViewController.swift` completes immediately:

- `GalavantShare/ShareViewController.swift:3`
- `GalavantShare/ShareViewController.swift:6`

That is fine for the current milestone because M4 owns capture. Just keep it visible
as "stub, not broken" so no agent accidentally treats it as implemented capture.

## Suggested jon-platform / shared-doc refinements

These are not Galavant-specific and may be worth folding into jon-platform:

1. Add a displayed-collection rule for deletes/reorders.

   If a view renders `filteredItems` or `sortedItems`, any `IndexSet` from
   `.onDelete` or reorder callbacks must resolve IDs from that same displayed
   collection, never from the source array.

2. Clarify the split-view navigation rule.

   One root `NavigationStack` in a `NavigationSplitView` detail can be the section
   stack. The trap is adding another nested stack inside that detail/panel for
   in-panel drill-downs. Use overlay/detail state there, as Galavant's
   `TripDetailContent` does.

3. Add a UUID-generation nuance.

   Database operations that create records should either accept IDs from callers or
   be called from a model that supplies dependency-controlled UUIDs. Direct `UUID()`
   in schema operations is convenient but should not be the default exemplar.

4. Add a cancellation note for one-shot model reads.

   Observed reads remain the default. A one-shot model read to seed editor-only
   state can be acceptable when isolated in a model, but it should not report
   `CancellationError` as a real issue.

5. Add a CLI verification note for macro-heavy Xcode projects.

   Xcode package macro trust can block headless builds before compilation. Agents
   should know when `-skipMacroValidation` is acceptable for verification, while
   leaving the human Xcode approval flow intact.

## Bottom line

Galavant is a strong exemplar for the way we should move forward: app-local product
docs, jon-platform for shared laws, table structs, observed reads, database-core
operations, pure read models, and platform-shaped UI. The main thing to improve is
not the architecture; it is tightening the edge cases so the exemplar does not teach
future agents the wrong small habits: wrong-array deletes, partial ADR-0008
hardening, stale docs, direct UUID creation, and ad hoc binding derivation.
