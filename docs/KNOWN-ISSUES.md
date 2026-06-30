# Known issues — beta-sensitive

Bugs we're tolerating for now, especially ones that may be Xcode/SDK **beta**
regressions worth re-checking as the betas evolve. Re-verify each on every new
Xcode 27 beta; delete an entry when it's fixed upstream or we work around it.

## `.inspector` swallows a view's `.toolbar` on iPad (Xcode 27 beta 1) — WORKED AROUND

*Observed 2026-06-23, iOS 27 iPad simulator, Xcode 27 beta 1. Surfaced when the
Ideas screen lost its entire trailing toolbar (filter / add / Discuss / Settings).*

Attaching `.inspector(isPresented:)` (our `.chatPanel`, ADR-0017) to a view that
also carries a `.toolbar` **silently drops the toolbar** when that view is the
root of a `NavigationSplitView` detail column on iPad — the nav bar shows only the
system sidebar-toggle, no title, no items. Confirmed by A/B: removing `.chatPanel`
brought the toolbar back; nesting it below the toolbar host fixed it with the panel
intact (verified by screenshot).

- **Root cause (hypothesis):** SwiftUI resolves the inspector's own toolbar
  contribution at the same nav container and discards the explicit `.toolbar` items
  when the inspector wraps the toolbar-bearing detail-root view.
- **Workaround (shipped):** attach `.chatPanel`/`.inspector` *inside* the
  toolbar-bearing view, not outside it — on Ideas, onto the inner `content`; on
  Trips, as the first modifier on `layout` (so `.toolbar`, applied after, wraps the
  inspector). `Galavant/Ideas/IdeasScreen.swift`, `Galavant/Trips/TripPlanningView.swift`.
- **Re-check on later betas:** if fixed upstream, the modifier can move back out;
  the nesting is harmless if it is.

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

## List drag-and-drop never lands a drop (Xcode 27 beta 1)

*Observed 2026-06-15 (M3d follow-up), iOS 27 simulator + device, Xcode 27 beta 1.*

Dragging a row in a `List` lifts it, but the **drop never completes** — the
console logs `Gesture: System gesture gate timed out` and nothing happens. Tried
for "drag an itinerary stop between days": three different drop surfaces, all
failed:

1. `.dropDestination` on the **section headers** — headers don't register as drop
   targets in a `List` (a standing limitation, independent of the beta).
2. The iOS 27 **reorder container** (`.reorderable(collectionID:)` +
   `.reorderContainer(for:in:)`) — the sanctioned cross-section path; flaky here,
   consistent with the **Someday reorder** issue above.
3. `.dropDestination` on the **rows** + an empty-day placeholder (the standard,
   usually-reliable surface) — also times out.

- **Read:** three surfaces failing on one beta ⇒ the beta's drag-and-drop /
  gesture subsystem, not our code.
- **Decision (Jon, 2026-06-15):** back the feature out (the `StopMenu`'s
  Move-to-Day / To-Be-Scheduled covers it); re-check on a later beta.
- **Fallback if it persists:** render the itinerary as a `ScrollView`/`LazyVStack`
  (no `UICollectionView` interception) instead of `List`; row `.draggable` /
  `.dropDestination` work reliably there. Tracked in docs/BACKLOG.md.

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

## Hardware Return doesn't submit the in-app browser's address bar on iPad (Xcode 27 beta) — PUNTED

*Observed 2026-06-30, iOS 27 iPad **device**, Xcode 27 beta. Browser feedback Stage D-6.*

With text typed in the in-app browser's address bar, pressing Return on a **hardware**
keyboard flashes the `NavigationSplitView` sidebar's "Browser" item but does **not**
submit/navigate. The key event routes to the sidebar's selection-bound `List` instead of
the focused address `TextField`'s `onSubmit`. The on-screen keyboard's "Go" works fine —
only the hardware Return is affected.

- **Tried (didn't help):** catching the key at the field with
  `.onKeyPress(.return) { submitAddress(); return .handled }` to consume it before it can
  bubble to the split view — the field's key handler never wins on this beta. Backed out
  (was branch `feat/browser-stage-d`, commit `9b27865`, not merged).
- **Decision (Jon, 2026-06-30):** chalk up to an iOS 27 **beta** focus-routing bug; punt.
- **Re-check on later betas.** Fallback if it persists: focus-scope the detail column, or
  drop the sidebar `List`'s selection participation while the address field is focused.
- **Code:** `GalavantLibrary/Sources/GalavantWeb/WebBrowserView.swift` (`addressBar`),
  host `Galavant/Navigation/AppContainer.swift` (sidebar `List(selection:)`).

## In-app browser clips some sites' fixed top navigation — PUNTED (per-site quirk)

*Observed 2026-06-30, iOS 27 iPad **device**, Xcode 27 beta. jan-hartwig.com. Stage D-5.*

The site's fixed top menu bar renders **above** the visible `WebView` area and can't be
scrolled into view (it's `position: fixed`). Confirmed the **same in both `.desktop` and
`.recommended`** content modes, so it is *not* the desktop-viewport layout — the page's
fixed header sits outside WebKit's visible viewport top in our embedded `WebView`.

- **Decision (Jon, 2026-06-30):** punt — per-site quirk, low value to chase. **Capture
  still works**: `page.currentDOM()` reads the full DOM regardless of what's scrolled into
  view, so the clipped header is cosmetic, not a data loss.
- **Re-check on later betas.** Only one site so far; if it turns out general, revisit
  top content-inset / safe-area handling on the `WebView`.
- **Code:** `GalavantLibrary/Sources/GalavantWeb/WebBrowserView.swift` (body `WebView(page)`).
