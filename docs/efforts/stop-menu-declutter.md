# Declutter the itinerary StopMenu

The clock-icon menu on an itinerary stop (`Galavant/Trips/StopMenu.swift`) has
become a junk drawer: a **clock** affordance that opens booking, notes, skip,
shortlist, *and* alternatives. This work re-homes each concern by its scope so the
clock menu means only **when**, and each other concern lives where that scope
lives.

Read first: `Galavant/Trips/StopMenu.swift`, `Galavant/Trips/TripItineraryView.swift`
(the row + accessory), `Galavant/Trips/PlanningRow.swift` (alternatives controls),
`Galavant/Trips/TripDetailContent.swift` (the in-panel detail overlay), and
`Galavant/Trips/TripPlanningModel.swift` / `+Scheduling.swift` (the actions).

House rules that apply: branch + PR to `main`, never push to `main` directly. If
you add a new Swift file, it must be declared in `project.yml`, then
`xcodegen generate`, and **both** `project.yml` and the regenerated
`project.pbxproj` are committed together. Verify with a build only — the reviewer
runs on device; do **not** install/launch a simulator:
`xcodebuild -scheme Galavant -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -skipMacroValidation build`
plus `swift test --package-path GalavantLibrary` for any schema/core change.

Land this as a **stack of small PRs** in the order below, not one mega-PR. Each
workstream is independently reviewable and testable, and workstream 4 is the
design-sensitive one Jon wants to feel out.

---

## 1. Retire "Move Earlier / Move Later" (drag covers it)

Drag-to-reorder within a day now works (`.reorderable()` in
`TripItineraryView.focusedDayList`). The two menu buttons in
`StopMenu.swift:57-66` were gated to exactly `case .day` (Anytime) stops — the same
population `.reorderable()` covers — so they're pure duplication. Remove them.

- Before deleting, confirm on device that `reorderable()` exposes a VoiceOver
  "move" accessibility action (the menu buttons were the accessible reorder path).
  If it does not, keep a minimal accessibility-only affordance rather than losing
  the capability outright.

## 2. Lifecycle actions → swipe actions

Move these three status transitions out of the menu onto row swipe actions. They
are all "demote this stop off its current slot," which reads as delete-adjacent.

- **To Be Scheduled** (`model.sendToBeScheduled` — only when placed & not
  calendar-linked)
- **Mark Skipped** (`model.markSkipped` — broad)
- **Move to Shortlist** (idea-backed: `model.unschedule`) / **Remove** (freeform:
  `model.remove`, no shortlist per ADR-0010)

Rules:

- **Freeform Remove is a genuine delete** — give it a **confirmation dialog** and
  **no full-swipe-to-trigger**. The other three are reversible demotions and may
  full-swipe freely.
- Split leading vs. trailing so three actions don't crowd one edge — suggest Skip
  (and freeform Remove) trailing/destructive-tinted, the "move" actions leading.
  Final arrangement is yours; keep it legible.
- **Attach-site wrinkle:** `.swipeActions` must sit on the *List row*. In the
  whole-trip path (`fullItinerary`) `stopRow` **is** the row, so it attaches there.
  In the **focused-day** path `stopRow` is folded inside
  `focusedDayStopCell`'s `VStack` and the *cell* is the row — attach the swipe
  modifier to the cell there, not to `stopRow`. Two attach sites.
- Swipe (horizontal pan) coexists with the row tap and the reorder long-press;
  verify no gesture conflict in the focused-day list, which has all three.

## 3. Note + Pin/Booking → a stop-scoped editor

Both `inlineNote` and `pinnedDate`/booking live on the **entry** (this stop on this
trip), whereas today's pencil (`model.editIdea`) edits the shared **Idea** record
(cross-trip). So these cannot simply move into the idea edit form — wrong scope.

- Introduce a **Stop editor** sheet that owns entry-scoped fields: the inline note
  (`editStopNote`) and the booking/pin (`editBooking` — pin date + booking
  details), and links out to the shared Idea for cross-trip fields rather than
  duplicating them. Freeform stops edit their note in the freeform editor already
  (`editFreeform`); fold booking into that path too so freeform and idea-backed
  stops reach booking the same way.
- Remove "Add Note" / "Edit Note" and "Pin Reservation" / "Edit Booking Details"
  from `StopMenu`. Keep the calendar-linked read-only "Time from Shared Calendar"
  label in the menu (it is a *when* statement) and keep the pinned-reservation
  glyph in the row accessory.
- **Keep the row pencil for now** — it opens this stop editor. (A later evaluation,
  tracked in `CURRENT_HANDOFF.md`, may collapse it once detail carries its own
  Edit.)

## 4. Row tap → ambient detail (design-sensitive; do last)

Today the row tap calls `model.selectStop` (highlights the map circle, brings the
Itinerary tab forward) and a separate **info button** calls `model.showDetail`,
which pushes the in-panel detail overlay (`TripDetailContent.swift:31-39` — an
opaque overlay swap keyed on `detailIdeaID` that covers the *list panel only*, never
the map).

- Extend the **row tap** so an idea-backed stop *both* selects (map highlight) and
  pushes the detail overlay — i.e. selection drives detail ambiently, reusing the
  existing `detailIdeaID` overlay, **not** a modal sheet and **not** a nested
  `NavigationStack` (see the comment at `TripDetailContent.swift:25-30` for why).
- **Remove the info button** from the row accessory (`stopRowAccessory`,
  `TripItineraryView.swift:490-501`). **Keep the pencil.**
- Freeform stops have no idea/detail — their tap stays select-only.
- This is the piece to build last and keep cleanly revertable; Jon will judge the
  feel on device before it's final.

## 5. "Add Alternative" → `+` on the alternatives controls row

`StopMenu.swift:102-111` is currently the only entry point for (a) the **first**
alternative on a scheduled stop that has no ring yet, and (b) the **Custom Stop**
variant. Note "Add Alternative" *also* already exists inside the expanded
`AlternativeSlotDisclosure` (`PlanningRow.swift:260`), but shortlist-only.

- Add a **`+` menu** to `AlternativeSlotControls` (`PlanningRow.swift:160`) offering
  both **From Shortlist** (`addAlternativeButtonTapped`) and **Custom Stop**
  (`addCustomAlternativeButtonTapped`), so both variants are reachable without
  expanding the disclosure. You may replace the disclosure's shortlist-only button
  or leave it; don't leave two inconsistent add paths.
- **The ring-less scheduled stop (decided):** `AlternativeSlotControls` only renders
  `if let ring`, so a scheduled stop with no alternatives yet has no controls row to
  hang the `+` on. **Decision (Jon):** surface a single low-emphasis
  `+ Add alternative` affordance on the row for scheduled stops that have no ring,
  offering the same From Shortlist / Custom Stop menu as the controls-row `+`. This
  lets "Add Alternative" leave `StopMenu` **entirely** — the entry point is then
  consistent whether or not a ring exists. Keep the affordance quiet (caption
  weight, secondary/tertiary foreground) so it doesn't add visual heft to every
  scheduled stop.

---

## The menu's end state

After all five, `StopMenu` contains only *when*: **Time of Day**, **Set/Change
Time**, **Move to Day / Set Day**, plus the calendar-linked "Time from Shared
Calendar" label and the pin/booking-while-unplaced edge handled by the stop editor.
The clock affordance and its contents finally agree.
