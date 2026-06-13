# Known issues — beta-sensitive

Bugs we're tolerating for now, especially ones that may be Xcode/SDK **beta**
regressions worth re-checking as the betas evolve. Re-verify each on every new
Xcode 27 beta; delete an entry when it's fixed upstream or we work around it.

## Someday reorder doesn't persist on fast navigation (Xcode 27 beta 1)

*Observed 2026-06-13 (M3b), iOS 27 simulator, Xcode 27 beta 1.*

Drag-reordering the Someday backlog on the Trips list and then tapping into a
trip *quickly* sometimes loses the new order.

- **Hypothesis:** SwiftUI's iOS-27 `reorderable()` delivers the move via the
  `reorderContainer` closure *after* the drop settles; a fast NavigationLink
  push preempts that closure before our `Trip.reorderSomeday` write runs (or the
  quick gesture registers as a tap, not a drag). The DB write itself is
  synchronous, so once the closure runs the order sticks.
- **Decision (Jon, 2026-06-13):** wait — we're on beta 1. Re-check as new betas
  land before changing code.
- **Fallback if it persists into later betas:** switch the Someday section from
  `reorderable()` to classic `List` `.onMove` (commits synchronously on drop;
  tap and drag are distinct gestures). Keep `reorderable()` for M3d's map/grid
  surfaces where it's the only option.
- **Code:** `Galavant/Trips/TripsScreen.swift` (`.reorderContainer(for: Trip.self)`),
  `GalavantSchema/TripOperations.swift` (`Trip.reorderSomeday`).
