# Effort — Taste Profile explains a missing identity; Planners can set "This is me"

**Status:** Done→done-log (2026-10-08) · **Summary:** on device, the Taste Profile editor showed no
"Your overlay" field, and nothing said why. The editor hides the field when this device doesn't know
which planner it is. The only way to set that is the Ideas screen's "Who are you?" sheet, which appears
on its own schedule. This effort shows the overlay section with a way to fix it, adds **This is me** to
Settings → Planners, and makes the editor pick the identity up live. No schema change, nothing synced:
identity is device-local (ADR-0008).

Follows `travel-profile-wiring` (#167) and ADR-0015 §3 as amended. It's part of the open-questions item
"Consolidate remaining management UIs into Settings" (planner identity).

## Today

- `TravelProfileEditModel` takes `plannerID` once, at `init`, from `SettingsModel.currentPlannerID`
  (the device-local `currentPlannerID` app-storage key). `TravelProfileEditView` shows the overlay
  section only `if model.plannerID != nil`. With no identity, the field is simply absent.
- Identity is bound only by `IdeasListModel.selectPlanner` / `createPlanner`, from the Ideas identity
  sheet (ADR-0008). `PlannerManagementModel` reads the key but can only rename and delete.
- The editor's doc comment is stale: it still says the entry point is a stub and that the profile
  "feeds every model call". The `travel-profile-wiring` brief asked for this fix, and #167 missed it.

## 1. The editor reads identity live and explains when it's missing

- `TravelProfileEditModel` reads `@Shared(.appStorage("currentPlannerID"))` itself, the same key and
  store as everywhere else, instead of taking `plannerID` at `init`. Drop the init parameter, and
  remove `SettingsModel.currentPlannerID` if nothing else uses it. When the key changes while the
  editor is open, load that planner's overlay.
- **No identity:** keep the **Your overlay** section, but replace the text editor with *"Choose who you
  are on this device to add your own taste."* and a **Choose Who You Are** row. The row pushes the
  Planners screen *inside the editor sheet's own `NavigationStack`*. That's safe: it's the sheet's
  stack, not the split-view detail column.
- **Identity set but not in the synced planners yet** (the row hasn't arrived): treat it as no identity
  for display, with the same message. Don't show an overlay keyed to a planner nobody can see.
- Fix the doc comment: Settings → Library presents the editor, and the briefs and chat read the profile
  (ADR-0015 §3 amendment).

## 2. Settings → Planners: This is me

- `PlannerManagementView` marks the current planner (it already computes `isMe`). Every other row gets
  a **This is me** action. Use a swipe action or a context menu; a plain tap stays rename.
- `PlannerManagementModel.setCurrentPlanner(_:)` writes the shared key, as `IdeasListModel.selectPlanner`
  does. It's device-local: no row is written and nothing syncs. Ask first when switching away from an
  existing identity: *"Use this device as Wendy? Votes and your taste overlay will be Wendy's on this
  device."* With no identity yet, don't ask.
- The delete guard is unchanged: you can't delete the current planner.

## Tests

**App** (`GalavantTests`):
1. Editor model with an empty key: no overlay to edit (`canEditOverlay == false`, or whatever the model
   exposes). Set the key to a seeded planner: it can edit and loads that planner's overlay.
2. Key set to a UUID with no planner row: treated as no identity.
3. `PlannerManagementModel.setCurrentPlanner` writes the key, and `currentPlannerID` reads it back.

## Done when

- One PR on branch `effort/taste-profile-identity`. `scripts/check-drift.sh` is green, and headless
  `GalavantTests` pass.
- No schema, migration, sync or contract change.
- The completing PR:
  - adds a DONE-LOG entry;
  - marks this brief Done in `docs/efforts/README.md`;
  - adds to `docs/device-passes.md` under **Verification gates**: *on a device or simulator with no
    identity, open Settings → Taste Profile: the overlay section explains and links to Planners. Mark
    yourself **This is me**, go back, and the overlay field appears;*
  - sets `docs/NEXT_UP.md` to exactly this block:

    ```
    # Next Up — Galavant Dev: Debug builds get their own bundle ID, app group, name and icon

    **Slices:** effort `galavant-dev-variant` (one PR, branch `effort/galavant-dev-variant`)
    **Briefs:** `docs/efforts/galavant-dev-variant.md`
    **Done when:** per the brief's "Done when"; verification per `docs/verification.md`.
    **Owed:** Jon's one-time portal setup (`.dev` App IDs, app group, container assignment, WeatherKit in
    both tabs) before his first device run. Identifiers and entitlements change, so the architect
    escalates the PR to Jon before merge.
    **Notes:** ADR-0050. Release must be unchanged: prove it with the Debug/Release identity table in the
    PR. The container stays the same; the app group never falls back to production. Start from a fresh
    `main`.
    ```
