# Effort — iPhone trip presentations + Ideas empty state

**Status:** Dispatched (2026-10-06) · **Summary:** on iPhone, most of the trip screen's sheets never
appear, and the Ideas empty state covers the rows under it. Both are view-layer defects found in
device dogfooding on 2026-10-06. No schema, sync, or model logic change.

## 1. Sheets hosted on the outer view never present on iPhone

**The cause.** On iPhone, `TripPlanningView.sheetLayout` presents the persistent bottom sheet
(`TripDetailContent`) from the base view. Every other `.sheet` attached to that base view, or to a
wrapper around it, then asks a view **that is already presenting** to present again, and SwiftUI
drops the request. The code already knows this: `showToday()` dismisses the detail sheet first
because *"otherwise SwiftUI drops the second presentation."* On iPad (`usesColumn`) there is no
bottom sheet, so the same code works. That is why this went unnoticed while dogfooding on iPad.

`TripDetailContent`'s doc comment states the current split: row-triggered sheets are hosted inside
it, toolbar-triggered ones on the outer host. That split is the bug, because on iPhone the outer
host is never free to present. Also, some row-triggered destinations live outside regardless.

**Hosted on the outer view today, and so dropped on iPhone:**

| Trigger (iPhone) | Destination | Host today |
| --- | --- | --- |
| Ideas list **Add Ideas** row and the empty state's button | `model.destination = .addIdeas` | `TripPlanningPresentationHost` |
| Ideas list **Documents** row (#149) | `.documents` | `TripPlanningPresentationHost` |
| Ideas list **Evaluate Recommendations** row | `.recommendationWorkspace` | `TripPlanningPresentationHost` |
| Toolbar **Recommend** | `.recommendationHandoff` | `TripPlanningPresentationHost` |
| Toolbar **N to book / Bookings** | `.booking` | `TripPlanningPresentationHost` |
| Toolbar **Start Day** | `showingStartDay` (view `@State`) | `TripPlanningPresentationHost` |
| Toolbar **Reconcile Calendar** | `showingCalendarReconciliation` (view `@State`) | `CalendarReconciliationPresentationHost` |
| Toolbar **Discuss** | `showingChat` → `ChatPanelPresentation`'s compact `.sheet` | `.chatPanel` on `layout(…)` |

Shape Trip works because `.sketch` is already hosted inside `TripDetailContent`. That makes it the
control case for the device pass.

**The fix: one home for the trip's presentations.**

- Move every `model.destination` sheet in `TripPlanningPresentationHost` into `TripDetailContent`'s
  presentation chain, next to `editorSheets`. That view is the top presentation on iPhone and a
  plain column on iPad, so presenting from it works in both layouts. Keep an extracted wrapper
  struct (as now) so the chain stays within the type checker's limits. Keep each sheet's
  `onDismiss` (`bookingSheetDismissed`) and content unchanged.
- **Start Day and Reconcile Calendar become `Destination` cases** (`.startDay`,
  `.calendarReconciliation`), replacing `showingStartDay` / `showingCalendarReconciliation`. That
  follows the house rule of one `Destination` enum, not `isShowingX` booleans. Reconcile keeps its
  `onDismiss: model.reloadCalendarTimeAuthority()`. `TripDetailContent` already receives the
  `reconciliationModel`.
- **Chat on iPhone.** When `!usesColumn`, attach `.chatPanel` to the presented `TripDetailContent`
  (inside the `sheetLayout` sheet) instead of to `layout(…)`. Keep the iPad placement exactly as it
  is: the inspector must stay below the toolbar host (see the KNOWN-ISSUES note quoted in
  `TripPlanningView`). The binding can stay `showingChat`. Chat is its own reusable presentation,
  not a trip destination, so leave it out of the `Destination` enum.
- **Leave alone:** Today (`fullScreenCover` with the existing dismiss-then-present dance) and
  Journey (iPad-only toolbar button).
- Delete `TripPlanningPresentationHost` and `CalendarReconciliationPresentationHost` if they end up
  empty. **Rewrite `TripDetailContent`'s doc comment** to state the rule: *every trip-screen sheet is
  presented from `TripDetailContent`, because on iPhone the outer view is already presenting it.*
  Add the same one-liner as a `docs/KNOWN-ISSUES.md` entry so the next sheet doesn't land on the
  outer host again.

## 2. The Ideas empty state is drawn over the list

`TripIdeasView` puts `ContentUnavailableView("No ideas yet")` in an `.overlay` on the whole `List`.
The list still has rows on an empty trip: the inline Add row (iPhone), the certainty summary
("Q3 2027 · 15 days"), and since #149 the Documents row. The overlay paints over them and takes
their taps.

**Fix:** remove the overlay. When `plan.isEmpty`, add an in-list `Section` after the Documents
section containing the empty-state message: icon, "No ideas yet", "Pull ideas from the pool onto
this trip." Add an **Add Ideas** button in that section **only when `showsInlineAdd` is false**
(iPad, where Add lives in the column's top bar). On iPhone the inline Add row already sits at the
top, so a second Add button would be a duplicate. Every row stays visible and tappable.

## Done when

- One PR on branch `effort/iphone-trip-presentations`.
- `scripts/check-drift.sh` green, plus headless `GalavantTests` (app views and models touched), per
  `docs/verification.md`. There's no new unit seam: this is presentation wiring. Don't build one.
- The PR description lists each moved presentation and its new host.
- The completing PR:
  - adds a DONE-LOG entry;
  - sets `docs/NEXT_UP.md` to `Nothing dispatched.`;
  - marks this brief Done in `docs/efforts/README.md`;
  - adds to `docs/device-passes.md`:
    - *iPhone, a trip with ideas, bottom sheet up: each of Add Ideas, Documents, Evaluate
      Recommendations, Recommend, N to book, Start Day, Reconcile Calendar (dated trip), Discuss,
      Shape Trip and Today opens, and dismissing returns to the sheet at its detent. Repeat on iPad
      (no regressions);*
    - *iPhone, an empty trip: the summary, Documents and Add rows are visible and tappable, with the
      empty message below them.*
