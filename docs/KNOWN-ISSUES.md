# Known issues — beta-sensitive

Bugs we're tolerating for now, especially ones that may be Xcode/SDK **beta**
regressions worth re-checking as the betas evolve. Re-verify each on every new
Xcode 27 beta; delete an entry when it's fixed upstream or we work around it.

## A `Map` steals taps from SwiftUI controls inset/overlaid over it (Xcode 27 beta) — WORKED AROUND

The trip-canvas `DayChipBar` pills went dead: you could drag the pill row
horizontally, but tapping a pill did nothing (no selection, no map reframe) on
both iPhone and iPad. Root cause: MapKit's `Map` ignores a `.safeAreaInset` /
`.overlay` layout inset and draws its **interactive** surface full-bleed under
those controls, and its own tap recognizer wins tap arbitration against a SwiftUI
`Button` on top. A `ScrollView` pan still works (SwiftUI's pan sits on top), and a
`TextField` still gains focus (why the map-search field kept working) — only the
discrete `Button` tap is lost.

**Partial workaround:** stack the chips in a real `VStack` row *above* the map
rather than insetting/overlaying them over it, so the map gets a bounded frame it
can't reach past. `Galavant/Trips/TripPlanningView.swift` (`canvas`) +
`Galavant/Trips/TripCanvasMapView.swift`. Costs the "floating chips over the map"
look.

**Residual — still broken (PUNTED, re-check next beta):** with the stacked row the
pills now register taps, but the **hit target is offset** — you must tap slightly
below-and-left of a pill to select it. A consistent directional offset like this is
a hit-test *coordinate* mismatch (the `Map` appears to poison safe-area accounting
for the surrounding views), not our layout — it reads as an SDK regression. It
worked fine before; likely to shift/resolve on a later beta. Not chasing a fragile
workaround for now.

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
- **Beta 5 cross-repo data point (2026-08-19, yes-chef):** single-collection
  `reorderable()` + `reorderContainer(for:)` **reorders correctly on beta 5**
  (`27A5237l`), verified on device. That covers the *mechanism*, so the fallback
  above — "switch to classic `List` `.onMove`" — should **not** be built on the
  assumption that `reorderable()` is broadly broken. It does **not** clear this
  entry: the failure recorded here is specifically **persistence lost on a fast
  `NavigationLink` push**, a race between the drop-settled closure and the push,
  which the yes-chef surfaces never exercise (no navigation out mid-drag). Re-check
  *that* gesture on beta 5 before deleting.

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
   consistent with the **Someday reorder** issue above. **Still the open question
   as of beta 5.** yes-chef confirmed the *single-collection* overload healthy on
   beta 5, but **neither app has a sectioned `reorderContainer(for:in:)` in the
   tree** — every one is `for:` with no `in:` — so this line is the only evidence
   about the sectioned overload that exists, and it is from beta 1. yes-chef
   ADR-0055 S2 builds the first sectioned container in either codebase and will
   answer it; **wait for that result before re-attempting `fullItinerary`.**
3. `.dropDestination` on the **rows** + an empty-day placeholder (the standard,
   usually-reliable surface) — also times out.

- **Read:** three surfaces failing on one beta ⇒ the beta's drag-and-drop /
  gesture subsystem, not our code.
- **Decision (Jon, 2026-06-15):** back the feature out (the `StopMenu`'s
  Move-to-Day / To-Be-Scheduled covers it); re-check on a later beta.
- **Fallback if it persists — STRENGTHENED, and now backed by beta-5 evidence
  (2026-08-19, cross-repo).** The fallback is "render the itinerary as a
  `ScrollView`/`LazyVStack` instead of `List`; row `.draggable` /
  `.dropDestination` work reliably there." **Yes Chef verified exactly that on
  beta 5** (`27A5237l`, iPad, on device): a drag from a `List` source lands
  successfully on a `.dropDestination` attached to a plain **`VStack`** day
  container (`yes-chef/YesChefApp/MenuDetailSections.swift:262`). Drag-and-drop
  itself is **not broken on beta 5**.
  *(An earlier note here, 2026-08-19 morning, claimed this fallback was disproven
  because a second Yes Chef drag onto that same container failed. That was wrong —
  the second drag failed for an unrelated local bug: two `.dropDestination`
  modifiers stacked on one view, where the inner shadows the outer. Retracted.)*
- **The hypothesis narrows: `List` as a drop *destination*, not `List` at all.**
  Yes Chef's **working** case is a `List` **source** → non-`List` destination. All
  three failures recorded below are `List` **destinations**. So a `List` source
  drags fine; suspicion belongs on `List` as the receiving container.
- **Yes Chef's not-allowed symptom was its own bug — root-caused and CONFIRMED on
  beta 5, so it is no longer evidence about this entry at all.** Cause: **two
  `.dropDestination` modifiers stacked on one view**, the inner accepting type A
  and the outer type B; the inner wins hit-testing and the outer is **dead**, so a
  type-B payload finds no acceptor anywhere. No error, nothing in the console.
  **Confirmed by inversion** (2026-08-19, on device): swapping the two modifier
  lines swapped which drag worked. Now a house rule —
  `jon-platform/docs/ios/ui-and-platforms.md`, *"Stacked `dropDestination` trap"*.
  **Audit our drop surfaces for this shape before carrying "it's the beta"
  forward.** (Their undeclared-`UTType` theory was investigated and **demoted**: the
  working payload type is equally undeclared. Still worth checking
  `ItineraryDropItem` / `AttractionInfo` have `UTExportedTypeDeclarations` entries,
  on correctness grounds, but it is not a drop-failure cause.)
- **Net for this entry: the beta explanation is weaker than when it was written.**
  One app's identically-shaped failure has been fully accounted for by local code
  on beta 5. Re-run all three surfaces here before carrying "it's the beta"
  forward.
- **Re-check on beta 5 (`27A5237l`) is owed and has not been run.** Cheapest probe:
  does `TripsScreen`'s / `TripIdeasView`'s existing `reorderable()` still reorder?
  A yes retires the *Someday reorder* entry above and narrows this one to the
  `.draggable`/`.dropDestination` path.
- **Cross-repo:** `yes-chef/docs/decisions/ADR-0055-drag-and-drop-on-the-sanctioned-reorder-path.md`
  carries the full analysis and the rebuild plan (sectioned `.reorderable(collectionID:)` +
  `.reorderContainer(for:in:)` for a day-sectioned list — directly applicable to
  `fullItinerary`). Also tracked in docs/CURRENT_HANDOFF.md.
- **Beta-5 update (2026-08-19) — the *single-collection* reorder path is unblocked; the
  itinerary is being rebuilt on it in slices.** The park above bundled two things this
  entry can now separate:
  - **Single-collection `.reorderable()` + `.reorderContainer(for:)`** is verified
    healthy on beta 5 (`27A5237l`) — load-bearing in this repo already
    (`TripsScreen.swift`, `TripIdeasView.swift`, shared `ReorderDifference+Apply.swift`)
    and re-confirmed on device in yes-chef. **Slice A** builds drag-to-reorder for stops
    **within one day** on the canvas day lens (`TripItineraryView.focusedDayList`) on this
    path: pickup limited to Anytime `.day` stops (only they carry a hand-order — ADR-0033),
    drop rewrites `dayRank` through the existing `TripIdea.reorderDayStops` primitive that
    "Move Earlier/Later in Day" already uses (those menu items stay as the fallback). No
    `List`-as-destination, no sectioned overload — so none of the three beta-1 failures
    below are in its path.
  - **Cross-day drag** (drag a stop between day sections in `fullItinerary`) stays parked.
    It needs the **sectioned** `.reorderContainer(for:in:)` overload, which **nothing in
    either codebase exercises yet** — every `reorderContainer` here and in yes-chef is
    `for:` with no `in:`. yes-chef ADR-0055 D3 is slated to land the first sectioned data
    point but is unbuilt as of this note. Do not treat beta 5 as clearing cross-day: the
    sectioned path is unproven, and Galavant's three beta-1 failures were all `List`-as-
    *destination*, the one hypothesis that survived. Re-check after the sectioned overload
    is exercised somewhere.
- **Slice A outcome (2026-08-19, on device, beta 5 `27A5237l`) — day-lens reorder WORKS,
  after two non-obvious gotchas, both cross-repo lessons.** Drag-to-reorder Anytime stops
  within one day (`TripItineraryView.focusedDayList`) now picks up and persists on device.
  Two traps cost real time and are worth carrying forward:
  1. **A custom `dragContainer` on a `reorderContainer` breaks the drop.** We added
     `.dragContainer(for:)` only to gate pickup to Anytime stops. `reorderContainer` is
     *already* its own drag container and drop destination; layering a custom `dragContainer`
     turned the reorder into a plain item-drag whose drop **always resolved back to the
     source's original slot** — every reorder was a silent no-op (the write fired and
     faithfully persisted the *unchanged* order, which read as "snaps back"). Removing the
     `dragContainer` (and the `Transferable` conformance that only fed it) fixed it. Custom
     `dragContainer` is for dragging OUT to other views/apps — **do not add one for a
     pure in-container reorder.** `TripIdeasView` reorders correctly precisely because it
     has none. Gate pickup in the persistence layer instead (ours no-ops a non-`.day`
     source).
  2. **Never fold a long-press `.contextMenu` into a reorderable row.** The travel-connector
     row carried a `.contextMenu` (a long-press) for its mode picker; folded into the
     reorderable stop cell it competed with the reorder lift (also a long-press), so a quick
     drag never committed — you had to hold until the menu appeared. Converting it to a
     tap-triggered `Menu` freed the long-press for the reorder. (Pairs with the "Stacked
     `dropDestination` trap" house rule.)
- **OPEN — folding day-anchored boundary rows into reorderable stop cells is wrong
  (2026-08-19).** `focusedDayCells` folds every non-stop timeline item — calendar
  constraints, stay check-in/out, home-base, the now-marker — into the *next* stop cell as
  `leading` content. Only the outgoing travel connector is genuinely stop-attached; the rest
  are **day-anchored** and must not move with a stop. Symptom on device: lifting the first
  stop produces a drag preview containing the hotel check-in and the calendar car-rental
  rows (screenshot 2026-08-19), and those events would re-seat if the stop moved. Fix
  direction is a design call (see CURRENT_HANDOFF): render day-anchored boundaries outside
  the reorderable `ForEach`, keeping only the trailing connector folded — the hard part is
  that boundaries interleave *between* stops by time, and a single reorderable `ForEach`
  must stay contiguous.
- **Cross-day drag (drag an event from one day to another in `fullItinerary`) is the
  sectioned-overload feature and is still gated.** It needs `.reorderContainer(for:in:)`
  (day = section), the overload nothing in either codebase exercises yet and that Galavant's
  three beta-1 failures (all `List`-as-*destination*) most implicate. Sequence: settle the
  boundary-row design in the day lens first, then attempt the sectioned container once
  yes-chef ADR-0055 D3 lands the first data point on it.

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
