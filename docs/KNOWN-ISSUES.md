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

## Keyboard text entry flaky in the iOS 27 simulator (environment, not our code)

*Observed 2026-06-13, iOS 27 simulator, Xcode 27 beta 1.*

Typing into a text field (e.g. New Trip → Name) sometimes does nothing; copy/paste
works. The console shows a haptics resource missing in the simulator:
`Error creating CHHapticPattern: … hapticpatternlibrary.plist … no such file`
(`/Library/Audio/Tunings/Generic/Haptics/Library/`). This is a **simulator image**
problem, not our text-input code — there's nothing to fix in the app.

- **Workaround:** Hardware ▸ Keyboard ▸ "Connect Hardware Keyboard" toggle, or
  type via the Mac keyboard / paste; or test on a real device.
- **Action:** re-verify on a device and on later simulator runtimes; expected to
  resolve without code changes.

## MapKit trips a Metal API Validation assert on the iOS 27 simulator (M3d)

*Observed 2026-06-14 (M3d map canvas), iOS 27.0 simulator (24A5355p), Xcode 27 beta.*

Running from Xcode, the map canvas aborts the app on first draw / first interaction with:

```
_MTLDebugValidateRenderPassDescriptorAndTrackAttachments:370: failed assertion `RenderPass Descriptor Validation
MTLRenderPassAttachmentDescriptor MTLStoreActionMultisampleResolve store action at attachment 0 requires resolve texture'
```

The offending render pass is **MapKit's own internal renderer** — we don't configure
any Metal/MSAA passes — so this is a MapKit + iOS-27-simulator-beta regression caught
by the **Metal API Validation** debug layer. It only fires when Xcode injects the
validator (Run); launching via `simctl` directly never reproduced it. Release builds
never enable validation, and real hardware renders maps fine.

- **Workaround (in place):** Metal API Validation disabled for the Run scheme via
  `project.yml` (`schemes.Galavant.run.enableGPUValidationMode: false` →
  `enableGPUValidationMode = "1"` in the generated `.xcscheme`, which is Xcode's
  *disable* value). Run `xcodegen generate` after pulling; if Xcode is open, it
  reloads the scheme (or reopen the project) so the change takes effect.
- **Action:** re-verify on each new beta and on a real device; remove the scheme
  override once MapKit/simulator stop tripping the validator.
