# Effort — Travel profile: a Settings entry, and the ChatGPT briefs and chat read it

**Status:** Queued (2026-10-08) · **Summary:** the taste profile already has storage, an editor and an
assembly helper, but nothing presents the editor and nothing reads the profile. Settings gets a **Taste
Profile** row. The outbound ChatGPT seed and recommendation briefs, and the in-app chat system prompt,
include the profile. **This is the first write to the synced `travelProfiles` table, so its Production
schema deploy is owed before TestFlight.**

Implements ADR-0015 §3 as amended 2026-10-08 (named readers, not `ModelClient`-boundary injection) and
`M6-EXECUTION.md` decision 4. No migration, no new column, no `GV-CONTRACT` bump.

## What exists

- **Storage.** `TravelProfile` ([TravelProfile.swift](../../GalavantLibrary/Sources/GalavantSchema/TravelProfile.swift)):
  one FK to `TravelParty`, and a loose optional `plannerID`. `nil` is the household profile; a set id is
  that planner's overlay. `setPreferences` and `removeProfile` are in
  [TravelProfileOperations.swift](../../GalavantLibrary/Sources/GalavantSchema/TravelProfileOperations.swift),
  with tests.
- **Editor.** `TravelProfileEditView` and `TravelProfileEditModel` (`Galavant/Settings/`). It has its own
  `NavigationStack` with Cancel and Save. Nothing presents it.
- **Assembly helper.** `TravelProfile.assembledProfile(travelPartyID:plannerID:from:)` combines the shared
  profile with **one** planner's overlay. Nothing calls it.
- **Prompt builders.** `RecommendationHandoffContract.seedBrief` and `.brief`
  ([RecommendationHandoff.swift](../../GalavantLibrary/Sources/GalavantSchema/RecommendationHandoff.swift)),
  called from `TripPlanningModel+Recommendation.swift`. `ChatModel.systemPrompt()`
  ([ChatModel.swift](../../GalavantLibrary/Sources/GalavantChat/ChatModel.swift)). Its comment says the
  profile is "the `ModelClient` boundary's job to inject", but nothing does.

## 1. One renderer for every reader

Add a pure function in `GalavantSchema`, for example
`TravelProfile.promptLines(travelPartyID:profiles:planners:) -> [String]`. It renders the **household**
view, because both readers plan for the couple:

- the shared profile first, as `Our travel taste: <text>`;
- then one line per planner with a non-empty overlay, as `<displayName>'s taste: <text>`. Order them by
  display name so the output is stable.

Trim each text and skip empty ones. Skip an overlay whose planner isn't in `planners`. That's an orphaned
row, so don't print a bare id. When nothing is left, return `[]`, and the readers then add nothing, not
even a heading.

**Withdraw `assembledProfile`** and its tests in `TravelProfileTests.swift`. Its single-overlay shape has
no reader, and the new renderer replaces it (house rule: withdraw orphaned code; don't park it).

## 2. The ChatGPT briefs

`seedBrief` and `brief` each take the rendered lines, for example `tasteLines: [String] = []`. They put
them directly after the `Trip:` line, and after `Trip notes:` in `brief`. The caller in
`TripPlanningModel+Recommendation.swift` fetches the party's profiles and planners and renders them.
The briefs stay pure.

**No contract change.** The `GV-CONTRACT` marker and the project instructions describe the **return**
shape. The brief is outbound prose, so the instructions Jon pasted into the ChatGPT project stay valid.
Don't bump the version.

## 3. The in-app chat

`ChatModel.systemPrompt()` adds the rendered lines between the persona paragraph and
`context.serialized()`, introduced by one sentence: *"The travel party's standing taste (use it to
shape suggestions; don't recite it):"*. Read the profile **each time the prompt is built**, through
`@Dependency(\.defaultDatabase)` as `ChatTools.swift` already does, so an edit applies to the next
message. Under test,
the database is seeded or empty, so output stays deterministic. Replace the stale comment above
`systemPrompt()`.

The chat's own **custom instructions** (`ChatInstructions`, device-local) stay as they are. They're
separate: per-device tuning, not shared taste.

## 4. The Settings entry

Add a **Taste Profile** row to `SettingsScreen`'s **Library** section, after **Planners**. It goes in
Library, not the AI section, because the profile is shared travel-party data that syncs, like regions,
tags and planners. The AI section holds device-local settings. The row's subtitle shows the first line
of the shared profile, or *"Not set"*.

- **Present the editor as a sheet.** It wraps its own `NavigationStack`, and pushing it from Settings
  would nest one inside the split-view detail (house memory: iPad nested `NavigationStack` trap).
- Pass the party id from `TravelParty.ensureDefault`, and the current planner from the
  `currentPlannerID` app-storage key that `PlannerManagementModel` reads. With no current planner, the
  editor already hides the overlay field.
- Fix the editor's stale doc comment ("Entry point is a stub…", "feed every model call…").

## Tests

**Package.**
1. `promptLines`: shared only; shared plus two overlays, in order; overlay only; all empty gives `[]`;
   an orphaned overlay is skipped; whitespace is trimmed.
2. `seedBrief` and `brief` with taste lines put them after `Trip:` / `Trip notes:`. With `[]`, the output
   is byte-identical to today's. Run the existing brief fixtures unchanged.
3. `GalavantChatTests`: with a seeded profile, `systemPrompt()` contains the taste sentence and lines.
   With none, it contains neither.

**App.** Headless `GalavantTests` if the edit model changes.

## Done when

- One PR on branch `effort/travel-profile`. `scripts/check-drift.sh` is green, and headless
  `GalavantTests` pass.
- **The PR description flags the first write to `travelProfiles`.** The architect escalates it to Jon
  before merge. Jon owes the Production deploy (below) before any TestFlight build from this code.
- The completing PR:
  - adds a DONE-LOG entry;
  - marks this brief Done in `docs/efforts/README.md`;
  - updates `M6-EXECUTION.md` decision 4 to "shipped" with the PR;
  - replaces the **Schema deploy before TestFlight** line's "Next case" in `docs/device-passes.md` with
    this gate: *on a development build with sync on, save a household profile **and** your overlay (so
    `plannerID` holds a value). In the CloudKit console, confirm `travelProfiles` has `travelPartyID`,
    `plannerID` and `preferences`. Deploy the schema to Production, then archive the TestFlight build.
    On TestFlight, edit the profile on one device and confirm it reaches the other; then run Discuss
    and a recommendation brief and confirm the taste lines are in the prompt;*
  - sets `docs/NEXT_UP.md` to `# Next Up` / `Nothing dispatched.`
