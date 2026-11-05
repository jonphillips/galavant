# Effort — One Hand off menu: Get Recommendations, Summarize Conversation, one Paste

**Status:** Ready · **Summary:** Seed from Conversation moves from the Ideas list into the trip's Hand
off menu as **Summarize Conversation**, beside **Get Recommendations**. The menu's single Paste works
out which of the two a pasted reply is, and a seed pasted without its `GV-SEED` line imports with a
warning instead of being rejected. The menu takes the house AI label and icons, and Discuss leaves the Ideas
screen. Implements [ADR-0048 Amendment 2](../../decisions/0048-trip-seed-handoff.md).
No schema, migration, sync-contract, or handoff-contract change.

## Today

- **Two doors, one machine.** The toolbar `Menu` in `TripPlanningView.swift` (≈ line 132) has
  **Hand off** → `model.startRecommendationHandoff()` (`candidatePlaces`), **Paste**, and **Ask now**.
  The **Seed from Conversation** row in `TripIdeasView.swift` (≈ line 89) calls
  `model.startSeedHandoff()` (`seedTrip`). Both present `RecommendationHandoffSheet`, which branches
  on `session.taskType`.
- **Paste knows only one purpose.** `pasteRecommendationFromClipboard()` (`TripPlanningView.swift`
  ≈ line 191) always starts a `candidatePlaces` session and runs `TripCandidate.decodeReturn`. Seed
  JSON fails there.
- **The seed review model lives in the sheet.** `RecommendationHandoffSheet` creates its
  `SeedReviewModel` in `init` as `@State`. Nothing outside the sheet can paste a seed, so the
  toolbar Paste has no way to reach seed review.
- **A missing `GV-SEED` line is fatal.** `SeedReturn.decode` (`GalavantSchema/SeedReturn.swift` ≈
  line 91) throws `.missingSeedMarker` before it looks for JSON. A missing token or contract marker
  already only warns (`SeedReviewModel.paste`).

## The work

### 1. `SeedReturn.decode` accepts a seed without `GV-SEED` (pure, `GalavantSchema`)

- If a line is exactly `GV-SEED`, behave as today.
- Otherwise slice the first JSON object from the whole text with the existing `jsonObjectSlice`. The
  narrative is the trimmed text before the object (often empty, and then the `summary` fallback
  applies as today). Add a warning to `decoded.warnings`: *"No GV-SEED line — imported the JSON
  anyway."* It shows in the review's Notes section like the other warnings.
- Still throw on no object (`.missingJSONObject`), malformed JSON, and an empty seed. Remove
  `.missingSeedMarker` if nothing throws it any more.
- Tests next to the existing `SeedReturn` tests: bare object; prose then object, no marker (prose
  becomes the narrative); a ```` ```json ```` fenced object; the marker path unchanged (the Denmark
  fixture still decodes the same); malformed and empty still throw.

### 2. Classify a pasted reply (pure, `GalavantSchema`)

A small value-level function next to `SeedReturn`, so the routing order is tested rather than
spread through the view. Suggested shape (adjust names freely):

```swift
public enum HandoffReturnKind: Equatable, Sendable { case candidatePlaces, seedTrip }
// Text with the GV-HANDOFF line already removed, if there was one.
public static func classify(_ body: String) -> HandoffReturnKind
```

Order: a line exactly `GV-SEED` → `.seedTrip`; else the first JSON value is an object with a
`bases` or `places` key → `.seedTrip`; else `.candidatePlaces`. The fallback is deliberate:
unrecognized text goes down the recommendations path, which already reports "Nothing was
imported" in the sheet, so there is no new error UI. Test each branch, including candidate JSON
(an array) and plain prose.

The token is checked before this, in the model (step 3), because it needs the session store.

### 3. One Paste in `TripPlanningModel`

Move the toolbar Paste's logic from `TripPlanningView` into the model, e.g. `pasteButtonTapped(_:)`:

1. Empty clipboard → today's visible "Clipboard is empty" feedback. Paste stays always enabled
   (platform rule: the tap is the check).
2. A handoff sheet is already open → paste into its session, as today, but through the
   presentation's seed model (below) when it's a seed session.
3. `HandoffRouting.route` gives a session ID that `handoffSessionStore` has, **for this trip**
   (`sourceID == trip.id`) → present that session and paste into it with its own `taskType`. No
   new session, so no "tagged for a different handoff" warning.
4. Otherwise `classify` the body, start a session of that kind
   (`startSeedHandoff()` / `startRecommendationHandoff()`), and paste into it. A token for some
   other trip lands here, and the existing mismatch warning still fires.

**Seam to pin:** `SeedReviewModel` is created by `TripPlanningModel` when it starts or reuses a
seed session and carried on `RecommendationHandoffPresentation` (e.g. `let seedReview:
SeedReviewModel?`). The sheet takes it from the presentation instead of creating its own `@State`.
Then the model can paste before presenting, and the in-sheet Paste and the toolbar Paste call the
same code. `pasteRecommendationResult(_:for:seedReviewModel:)` loses its optional parameter.

### 4. The menu and the sheet titles

- Toolbar menu (keep the single `ToolbarItemGroup`, per `docs/KNOWN-ISSUES.md`):
  - The menu's own label becomes **AI** with a new `Icon.ai` (`sparkles`), per jon-platform
    `docs/ios/ui-and-platforms.md` § The AI entry point. It was "Hand off" with `Icon.handoff`.
  - **Hand off** becomes a submenu with `Icon.handoff` (`sparkles.square.filled.on.square`), not
    `Icon.recommend`, holding **Get Recommendations** (`startRecommendationHandoff`) and **Summarize
    Conversation** (`startSeedHandoff`), in that order.
  - **Paste** is unchanged in label, icon, and order.
  - **Ask now** keeps its label and order. Its icon becomes a new `Icon.askNow`
    (`text.bubble.badge.sparkles`), and it still swaps to the checkmark while chat is open.
  - `Icon.recommend` stays `sparkles` for the Evaluate surfaces.
- Sheet door titles: "Hand off · Get Recommendations" (already) and **"Hand off · Summarize
  Conversation"** (was "Seed from Conversation"). Leave the review titles alone.
- Remove the **Seed from Conversation** button from `TripIdeasView`. Documents stays in its section.

### 5. Remove Discuss from the Ideas screen

Jon's call, 2026-11-04; see [ADR-0017's amendment](../../decisions/0017-context-aware-chat-window.md). In
`IdeasScreen.swift`, remove the toolbar button, `showingChat`, the `.chatPanel` modifier and its
comment, and `poolChatContext`. Delete `Icon.chat`, which has no other use. **Keep** `ChatContext.pool`,
`PoolContext` and their tests in `GalavantChat`, so this stays cheap to bring back.

## Out of scope

The brief and project-instruction text (still asks for `GV-SEED`), any contract marker version, the
Evaluate Recommendations row, the Evaluate screen, and the shared `HandoffMenu` view (brief
[`handoff-menu-adoption`](../handoff-menu-adoption.md)).

## Done when

- `swift test` for `GalavantSchema` is green with the step 1 and 2 tests; the app builds
  (`quiet-run`, compile only, no simulator walkthrough).
- The Ideas list has no seed row. The Hand off submenu has both purposes. Paste is the only paste
  entry outside the sheets. The menu reads AI with `sparkles`, and the Ideas toolbar has no Discuss.
- `docs/device-passes.md` keeps the **Hand off purposes** gate (added with this brief) until Jon
  clears it.
