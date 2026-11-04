# Effort — Chat access: stage travel options from chat into Evaluate

**Status:** Ready · **Summary:** Implements [ADR-0052](../decisions/0052-chat-access-over-mcp.md) and jon-platform
ADR-0009. First lifts Yes Chef's iCloud Drive transport into a shared `ChatAccessKit`. Then a local `galavant-mcp`
helper gets one tool, `stage_trip_return`, staged sets appear as From Chat rows in Evaluate, and one tap imports a set
into the workspace. Seeds and read tools follow. No synced schema or migration change; S2 adds the iCloud Documents
entitlement. Needs `hand-off-purposes` landed first.

**Read first:** ADR-0052, jon-platform ADR-0009, jon-platform `docs/agent-collaboration.md` § "Dispatches whose code
lands in jon-platform", and yes-chef `YesChefMCP/` plus `YesChefApp/ChatAccess*.swift`, the source being moved.

Each slice is its own dispatch. Stop after each one.

## Today

- **No MCP anywhere in Galavant.** The only way back from chat is Paste (`hand-off-purposes` makes it one button).
- **Evaluate lists only imported sets.** `EvaluateQueueModel.entries` (`Galavant/Evaluate/EvaluateScreen.swift`) needs
  `hasCommittedRecommendationCandidates`, which needs at least one row committed by hand in
  `RecommendationCandidateReview`.
- **The paste logic is in the app target.** `pasteRecommendationResult` is in `TripPlanningModel+Recommendation.swift`,
  and the import needs it without a `TripPlanningModel`.
- **`TripIdea.commit(candidate:into:in:)` already dedupes** against live trip rows and returns the existing row.
- **The container is CloudKit-only.** `project.yml` sets `com.apple.developer.icloud-services: [CloudKit]`.
- **The transport lives in Yes Chef's app.** See the table in ADR-0009.

## S1 — The lift: `ChatAccessKit`, inbox half

Three PRs, in this order. **Shared code escalates to Jon,** so don't merge the jon-platform PR on an architect approve.

### 1. jon-platform: create the package

Title: `Galavant chat-access S1 — ChatAccessKit`. New `packages/ChatAccessKit`, iOS 26 and macOS 26, depending on
Foundation, `LLMHandoffKit`, and `swift-dependencies`. Move these from Yes Chef, keeping behavior:

| Kit | From |
| --- | --- |
| `ChatAccessFolder` (`isDevelopment` has **no default**; keep `exportsURL`) | `YesChefCore/ChatAccessFolder.swift` |
| `ChatAccessContainerClient`: `resolveFolder`, `resolveAndCreateInbox`, `static func live(containerIdentifier:isDevelopment:)`. Its unavailable error takes the app's name | `YesChefApp/ChatAccessFolderClient.swift` |
| `ChatInboxFileClient`: `read`, `claim(folder, url, kind)`, `maintain(folder, kinds, now)`, `static let live` | `YesChefApp/ChatAccessInboxFileClient.swift` |
| `ChatInboxWatcher`: `init(folder:)`, `snapshots: AsyncStream<[ChatInboxSnapshot]>`, start and stop. Owns the query and observers, and requests downloads for items that aren't current | the query code in `YesChefApp/ChatAccessInboxModel.swift` |
| `ChatInboxItemKind` (`fileExtension`, `expiresUnclaimed`, `datesProcessedByClaim`), `ChatInboxSnapshot` (`url`, `name`, `isCurrent`) | `ChatAccessInbox.MetadataSnapshot`, minus `recipeName` |
| `ChatInboxRetention`: `interval` (30 days), `expiredUnclaimed`, `expiredProcessed` | `ChatAccessInbox.expired`, `expiredReturns` |
| `ChatAccessHelperFolder`: `containerURL(for: containerIdentifier, home:)` (`iCloud.a.b` to `~/Library/Mobile Documents/iCloud~a~b`), `existing(containerIdentifier:isDevelopment:) throws` (refuses to create a missing container), `isDevelopment(arguments:)` (`--variant dev`) | `StageContext.stagingFolder`, ADR-0060 D5 |

The retention rules must reproduce Yes Chef's exactly: `json` has `expiresUnclaimed: false, datesProcessedByClaim: false`
(staged date, falling back to modified date), and `ycreturn` has `true, true` (touch on claim, then modified date, falling back to
staged date). Move the matching tests from `ChatAccessFolderTests` and `ChatAccessInboxTests`. **The one-time probe cleanup
stays in Yes Chef.**

Also add `scripts/install-mcp-helper <package-dir> <product>`, which does what `install-yeschef-mcp` does, with a test in
`scripts/tests/` and a line in `scripts/README.md`. Add the package to `README.md`'s list and a row to `EXTRACTION-NOTES.md`.

**Verification, named in the PR body:** `scripts/quiet-run swift test --package-path packages/ChatAccessKit` and
`scripts/tests/*.sh` for the new script.

### 2. yes-chef: delete the copies and adopt the kit

Branch from a fresh `main` once the package PR merges, after checking that no open Yes Chef PR touches these files.

- Delete what moved, and keep the app's dependency keys as thin wrappers over the kit's `live` values. `ChatAccessInbox`
  keeps only its rows, routing, and names. `ChatAccessInboxModel` keeps everything except the query, which it reads from
  `ChatInboxWatcher`.
- `scripts/install-yeschef-mcp` becomes a call to the shared script, with the same install path.
- **The one behavior change, the Dev fix:** Debug builds pass `isDevelopment: true`. `YesChefMCP/main.swift` reads
  `--variant dev` through `ChatAccessHelperFolder`. Remove the stale comment in `ChatAccessFolderClient`.
- Add a dated note to ADR-0060: the transport moved to `ChatAccessKit`, and D5 is now true.
- **Records:** a Yes Chef `DONE-LOG.md` entry, and a `device-passes.md` gate: on TestFlight, a staged recipe and a staged
  hand-off return both still open and discard; Yes Chef Dev on the same device doesn't list them.
- **Verification:** `scripts/check-drift.sh`, `YesChefTests`, and the helper's tests.

### 3. galavant: records

This PR carries only the records: a `DONE-LOG.md` entry naming both branches and the jon-platform PR, and the `NEXT_UP.md` advance.

**Done when:** one copy of the transport exists, Yes Chef passes its gate, and Vinyl Fever is untouched.

## S2 — Candidates: helper, tool, Evaluate rows, one-tap import

### Pure, in `GalavantSchema`, test-first

- **`RecommendationHandoffContract`:** `brief` and `seedBrief` add `GV-TRIP: <uuid>` and the finalize line after
  `session.header`. Finalize line: *call `stage_trip_return` with this trip if the chat has it; otherwise start the reply
  with the `GV-HANDOFF:` line.* `projectInstructions` and the marker don't change. Add `chatServerInstructions`: an opening
  whose first 512 characters stand alone and name the tool, then `projectInstructions`, then the rule to print the return
  for pasting if a tool fails.
- **`StagedTripReturn.validate(_ text:) throws -> Validated`:** the one door the helper and the app both use. Remove a
  `GV-TRIP` line; route the token if there is one; `marker.strippingMarker` (a newer marker throws, and missing or older is
  silent); `HandoffReturnKind.classify`; then decode. `Validated` is an enum, so the states can't mix:
  `.candidates(token: UUID?, [TripCandidate], note: String?)` or `.seed(token: UUID?, SeedReturn)`. Reject a candidate set
  with no usable title. The paste door also strips `GV-TRIP`.
- **`RecommendationSetImport.apply(candidates:note:into tripID:session:now:in db:) throws -> Result`:** merges with
  `storeRecommendationCandidates`, commits every unlinked candidate with `TripIdea.commit`, links each one, sets
  `importedAt` and `.imported`, and saves a note as a `TripDocument` (`.pasted`). A nameless candidate takes
  `suggestedTitle`. It returns the updated session and the remaining count. Move shared logic here from
  `commitRecommendationCandidate` rather than copying it.
- **`StagedTripReturnRow`:** a pure projection from `[ChatInboxSnapshot]`, known trips, and cached `Validated` results, with
  `enum Destination { candidates(Trip, count), seed(Trip, placeCount), unknownTrip(UUID), unreadable(String) }` and a download
  state. The trip comes from the file name's slug, so a row can name its trip before the download finishes. Every file is its
  own row, newest first. No superseding: a second stage from one chat may add options, not replace them.
- **Tests:** each `validate` branch, including an array, an object with `candidates`, a fence, curly quotes, a bare object, a
  newer marker, an echoed `GV-TRIP`, and an empty set. Import is idempotent, and a re-run after a simulated failure makes no
  new rows. A matching live row is linked, not duplicated. Rationale lands in `inlineNote`. No pool `Idea` is created. Token
  reuse: the same session on this trip merges; a session on another trip doesn't. 512-character opening. Instructions contain
  `projectInstructions` verbatim.

### The helper, `GalavantMCP/`

A macOS-only package, shaped like `yes-chef/YesChefMCP` (`Package.swift`, a server target, a thin `main`, a test target).
Keep it out of the app's package graph. Server name `galavant`, container `iCloud.com.jonphillips.galavant`.

- Tool `stage_trip_return`, required `trip` (UUID string) and `text`, `additionalProperties: false`, annotations
  `readOnly: false, destructive: false, openWorld: false`. The description says to call it instead of printing the return and
  spells out what `text` is.
- It parses `trip`, runs `validate`, then `HandoffInbox(root: inboxURL, fileExtension: "gvreturn").stage(text, slug: trip, now:)`.
  **In this slice, a `.seed` return gets an error telling the model to print it for pasting.**
- Errors come back as `isError` with the reason. A missing `trip` says to tap Hand off in Galavant and paste the brief here.
- The result: `{staged: "8 options", next: "Review them in Galavant → Evaluate."}`. No paths.
- Tests use `MCPServerKit`'s in-memory harness and a temporary container: stages a good return with the expected name and
  bytes; a bad return writes nothing; a missing container is refused and not created.
- `scripts/check-drift.sh` runs these tests too.

### The app

- **`project.yml`:** `com.apple.developer.icloud-services: [CloudKit, CloudDocuments]`, and add
  `com.apple.developer.ubiquity-container-identifiers: [iCloud.com.jonphillips.galavant]`. Declare `ChatAccessKit`. Regenerate
  and commit both files. **Not published:** no `NSUbiquitousContainers`.
- **Variant:** Debug is Galavant Dev (ADR-0050), so it passes `isDevelopment: true`.
- **Settings:** a device-local **Chat Access** switch, off by default, with a short status line. When it's off, the app resolves
  no container, runs no watcher, and shows nothing in Evaluate.
- **`ChatInboxModel`:** thin, `@Observable`, owned by `AppContainer` so the badge works from any section. It holds the watcher,
  reads and validates current files once each, and exposes rows plus `readyCount`. Prepare and maintain on foreground, as
  Yes Chef does, with the `gvreturn` kind (`expiresUnclaimed: true, datesProcessedByClaim: true`). Inject the kit's clients as
  dependencies.
- **Evaluate:** a **From Chat** section above the queue, plus `.badge(readyCount)` on the Evaluate item. A row shows the trip,
  count, and staged time, and "Downloading…" while it isn't current. Update the empty state to mention it.
  - **Tap a candidates row:** `apply` in one write, save the session, claim, then set `router.openEvaluateEntry` to the new
    entry. The session is the token's if this device has it for this trip. If not, make one **with the token's ID**, or with a
    new ID when there's no token. If nothing remains to process, say every option is already on the trip and stay on the queue.
    On `alreadyClaimed`, drop the row quietly.
  - **Discard:** claim. Nothing else.
  - **`unknownTrip`:** "This trip isn't on this device yet", with **Copy** and **Discard**. `unreadable` shows the error, with the
    same two buttons.
- Don't nest a `NavigationStack` here. `openEvaluateEntry` already handles both layouts.

### Docs

`docs/chat-access-setup.md`, indexed in `docs/README.md`: only the helper path, install command, port, tools, and how to reinstall
and refresh. The general ops recipe stays in jon-platform's `mcp-access.md`.

**Done when:** `scripts/check-drift.sh` is green (schema and helper tests, app build). No simulator walkthrough. The gate in
`docs/device-passes.md` stays until Jon clears it.

## S3 — Seeds

- The helper accepts `.seed`, and its result says `Review it in Galavant → Evaluate.`
- A seed row shows the trip and place count. The tap sets `router.openTrip` and the section, then asks
  `router.planningModel(for: trip)` to present seed review with this text through the code `hand-off-purposes` added. Go through the
  model's `destination`, so the existing trip view hosts the sheet: outer-hosted sheets drop silently on iPhone.
- **Claim on commit.** `RecommendationHandoffPresentation` carries an optional staged item, and a successful
  `SeedReviewModel.commit` claims it. Dismissing without committing leaves the row.
- Tests: `validate` and the row projection for seeds, plus claiming only after a commit.

**Done when:** the gate's seed line passes, and paste still works for seeds.

## S4 — Read tools: start the chat in the assistant

Same three-PR order as S1 for the shared part.

- **Kit, export half:** `ChatAccessExportReader` (newest file, materialize under a deadline, cache by path and modified date, returns
  bytes), `ChatAccessExportWriter` (atomic coordinated per-device file, stable installation ID, 15-minute throttle), and
  `ChatAccessHelperProcess.enableDatalessMaterialization()`. Moved from `ChatAccessReadTools.swift`, `ChatAccessExportModel.swift`, and
  `YesChefMCP/main.swift`, with their tests. Yes Chef adopts them, with no behavior change. Its export gets the same device check.
- **`GalavantChatExport` (schema), version 1:** `generatedAt`, `device`, and trips, each with ID, name, dates, notes, stops, stays,
  ruled-out places, taste lines, and considering and shortlisted titles. Reuse `stopSummary` and the ruled-out summary (make it internal)
  so a brief and `get_trip` can't disagree. A newer version is a typed error. No images, sync metadata, or file paths.
- **Builder and writer in the app:** on background and from a **Refresh** in Settings, gated by the Chat Access switch. Run the read
  off the main actor under a background-task assertion, using what `launch-lock-suspension` added. Build each trip's plan **once**:
  `TripPlan` rebuilds on each access, which caused the August itinerary hang.
- **Tools:** `list_trips` and `get_trip(trip)`, marked read-only, each reporting the export's age. Result sizes are capped. "No export
  yet" tells Jon to open Galavant and tap Refresh.
- **`stage_trip_return`** rejects a trip ID the export doesn't contain, sending the model back to `list_trips`. With no export at all, it
  behaves as in S2: a stale or missing export shouldn't block a brief that carries a good ID.
- **Instructions:** the opening says a chat with no `GV-TRIP` line starts from `list_trips`.

**Done when:** a chat that never saw a brief can list trips, read one, and stage to it. Drift gate green. Gate in `device-passes.md`.

## Out of scope

- Plugin skills (ADR-0052 OQ2).
- Any change to Paste, its row-by-row sheet, or the handoff contract version.
- Making sets sync, or moving `HandoffSession` out of device-local storage.
- `CloudSyncKit`'s backup code, and adopting automatic backups in Galavant.
- Flights, trains, and other options Evaluate can't resolve to a place.
- A Mac mini move: `mcp-access.md` already says to move all the tunnels together.
