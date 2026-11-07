# Effort — Taste notes: keep what we learn about places, in our own words

**Status:** Ready · **Summary:** Slice 1 of [ADR-0053](../../decisions/0053-taste-record-and-region-guide.md). A synced table of
dated notes in Jon's and Wendy's own words, about a saved place, an unsaved place, or nothing in particular, for restaurants,
hotels, and everything else. People can add and browse them, import them from past chat conversations through a row-by-row
review, and briefs and in-app chat read them. **Adds one synced table: a permanent CloudKit schema change.** No change to the
hand-off contract or to Evaluate.

**Read first:** ADR-0053 (D2–D4), ADR-0015 (the `TravelProfile` and `IdeaEvaluation` pattern and its amendment), jon-platform
`docs/ios/persistence-and-sync.md` § The CloudKit laws, and `docs/ios/semantic-fidelity.md`.

**Privacy.** This repo is public. Fixtures, tests, previews, and demo data use invented places and invented words. Never
commit a real note, conversation, or export.

## Today

- `TravelProfile` is the closest shape: one real FK to `TravelParty`, a loose optional `plannerID`, and
  `TravelProfile.promptLines`. It's read by `TripPlanningModel+Recommendation.tasteLines(for:)` for both briefs and by
  `ChatModel.systemPrompt()`.
- `ResolvedIdeaContext.serialized()` (`GalavantChat/ChatContext.swift`) renders one idea for in-app chat.
- Tapping an idea in Ideas opens `IdeaFormView`. `IdeaDetailView` is presentation only, opened from `TripDetailContent` and
  `TodayView`, and takes its evaluations as a parameter.
- `SeedPoolMatch.match` and `SeedMatchKeys.make` (`GalavantSchema/SeedMatching.swift`) match a name and locality to saved Ideas.
- `SeedReturn.decode` and `jsonObjectSlice` show the delimiter-not-gate paste decode (ADR-0048 Amendment 2).

## The work

### 1. The record (`GalavantSchema`)

```swift
@Table public struct TasteNote: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var travelPartyID: TravelParty.ID  // the one real FK; rides the share, cascades
  public var plannerID: Planner.ID?         // loose. Whose words; nil = both of us
  public var ideaID: Idea.ID?               // loose. A saved place it's about, if any
  public var placeName: String?             // the place in text; set whenever it's about a place
  public var body: String                   // the note, verbatim
  public var source: TasteNoteSource        // .planner | .conversation (String raw values, stable)
  public var sourceDetail: String?          // where a conversation note came from, as text
  public var notedAt: Date                  // when it was said, if known; otherwise when it was saved
}
```

- **Append a new migration** ("Create tasteNotes table (ADR-0053)") after the last one in
  `DatabaseMigrationRegistrationsB.swift`. Never edit a shipped one. Add `TasteNote.self` to the synced list in
  `GalavantCloudSync.swift`.
- **The read side can't express a bad state.** Expose a computed subject, along these lines: `.general`,
  `.place(name:ideaID:)`. Both `ideaID` and `placeName` nil is general, and `placeName` is what renders. Writes go through ops
  that keep `placeName` set whenever `ideaID` is. A write can't produce an empty body.
- **Notes survive what happens around them.** This differs from `IdeaEvaluation`, so test it directly:
  - **Idea deleted:** the note stays and shows its `placeName`. A missing `ideaID` means an unsaved place, not an orphan to
    drop.
  - **Ideas merged:** repoint to the survivor (`IdeaMerge`).
  - **Travel parties merged:** repoint, and count notes when deciding whether a party is populated (`TravelParty.swift`,
    next to the `IdeaEvaluation` and `TravelProfile` lines).
  - **Planner deleted:** clear `plannerID` and keep the note. `PoolOperations` deletes that planner's `TravelProfile`
    overlays; a note isn't an overlay, so don't copy that.
- Accept IDs and dates as arguments on new ops, with the model supplying `@Dependency(\.uuid)` and `\.date`.

### 2. Rendering notes for a reader (pure, `GalavantSchema`)

`TasteNote.promptLines(notes:planners:limit:)` is the one function every reader uses, so a brief and later `get_trip` can't
disagree.

- Newest first. One line per note, with its date (year and month), whose words, the place if any, and the body.
- It opens with a line that says these are the party's own words, to be argued from by name and not recited.
- **Cap it.** Suggested: 80 notes or 12,000 characters. When it leaves notes out, the last line says how many. Declare this
  boundary **intentionally lossy** in code, per `semantic-fidelity.md`.
- Test ordering, the cap, the left-out line, general and place lines, a deleted planner, and no notes (returns nothing).

### 3. The readers

- **Both briefs:** add the lines after the existing taste lines in `tasteLines(for:)`.
- **In-app chat:**
  - `ResolvedIdeaContext` gains that idea's notes, in every tier.
  - `ChatModel.systemPrompt()` adds the whole set **only when `activeTier` is frontier.** On-device context is too small for
    it.
- **`get_trip` (`chat-access` S4):** whichever effort lands second wires this in, with the same function. `chat-access.md` S4
  says the same.
- Nothing else reads notes: not extractors, not `PlaceIntelligence`, not `ModelClient` (ADR-0015's amendment).

### 4. Adding and browsing

- **Settings → Library → Taste Notes,** beside Taste Profile. A list, newest first, with search over body and place. Add, edit,
  and delete with confirmation. Editing keeps the row's identity. This is a holding spot until the guide exists.
- **The add sheet** has a body field (dictation-friendly, no required structure), whose words (me, Wendy, both; defaults to the
  current planner), and an optional place: search saved Ideas of any kind, or type a name. Typed names stay unsaved places and
  mint no Idea.
- **`IdeaFormView`,** for an existing idea: a Taste Notes section listing that idea's notes, with Add. Put its state in a small
  child model. `IdeaFormModel` is already 509 lines.
- **`IdeaDetailView`:** a read-only section, passed in as `evaluations` is. `TripDetailContent` and `TodayView` supply it from
  a plain observed query, not through `TripPlan` (each access to the plan rebuilds it).
- **Hotels get no special path.** A saved hotel is an Idea. A freeform stay or a hotel never saved uses a typed name. No UI on
  the stay itself in this slice.

### 5. Importing from a conversation

- **Taste Notes toolbar → Import from Conversation.** Two actions: **Copy Prompt** and **Paste**, with Paste always enabled (the
  tap is the check).
- **The prompt** is one Core constant (`TasteNoteContract`) that asks the assistant to go through this conversation or what it
  knows, covering restaurants, hotels, and general travel taste. It should prefer the person's exact words, mark its own
  summaries as summaries, name the place when there is one, say why, and invent nothing. It returns the shape below.
- **The return:**

  ```jsonc
  GV-NOTES                      // delimiter, optional (ADR-0048 Amendment 2)
  { "notes": [{
      "note": "…",              // required
      "words": "person",        // person | summary; a missing value means summary
      "who": "jon",             // jon | wendy | both, matched to planners; anything else means both
      "place": "…",             // optional
      "locality": "…",          // optional, for matching only
      "date": "2026-03",        // optional: year, year-month, or full date
      "from": "…"               // optional, becomes sourceDetail
  }] }
  ```

  Decoding is pure and in `GalavantSchema`. It's **lossless-or-loud**: no object, malformed JSON, or no usable notes shows a
  visible error and imports nothing. A row with no `note` is reported, not silently dropped. Unknown fields are ignored. Tests
  next to `SeedReturn`'s.
- **The review is row by row, and this door is review-dependent:**
  - Each row shows the note, editable, whose words, the place, the date, and the source.
  - A row with `words: summary` is **labeled as the assistant's summary**, so it's plain before anyone keeps it.
  - A place runs through `SeedPoolMatch`. One match links the Idea, several ask, and none keeps a typed name. Never search Maps
    and never mint an Idea here.
  - A note whose body and place exactly match a saved note is marked **Already saved** and starts unselected.
  - **Nothing starts selected.** Each row takes a tap to keep, with a Select All for a list someone has read. Saving writes
    the chosen rows in one transaction with `source: .conversation`.
- **No hand-off session or token.** A note has no target to route to, so this door needs none of that spine. It stays apart from
  the Hand off menu's Paste.

## Out of scope

The dossier and region guide (S2, S3), recommendation records (S4), the universe, any category or rating field on a note,
MCP tools for notes, Siri or App Intent capture, UI on stays, and changing `doNotDo` filtering.

## Done when

- `swift test` for `GalavantSchema` and `GalavantChat` is green, covering the record's survival rules, `promptLines`, and the
  decoder. `scripts/check-drift.sh` passes, and the app builds through `quiet-run`, compile only, with no simulator walkthrough.
- **This slice adds a synced table.** NEXT_UP's **Owed** line names the deploy: push `tasteNotes` from a development build, then
  deploy the schema, before the TestFlight build. The seam ledger's *App schema fields checked against CloudKit Production* row
  names Galavant's next synced schema change as its trigger, and this is that change. Add the new fields through
  `EXPECTED_SCHEMA_FIELDS` in `testflight.conf` (jon-platform `docs/ios/testflight.md`). If that gate has changed by then, raise
  it on the PR.
- `docs/device-passes.md` keeps the **Taste notes** gates (added with this brief) until Jon clears them.
