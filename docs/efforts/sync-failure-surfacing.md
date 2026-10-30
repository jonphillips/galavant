# Effort — Sync status reports what didn't sync

**Status:** Done (2026-10-30) → DONE-LOG · **Summary:** #176 taught the Settings sync row the new
`.needsAttention` state, but `SyncHealthModel` never feeds `SyncHealth` the two counts behind it, so the
row can still read "Up to date" while rows have never reached CloudKit. This effort calls
`CloudSync.syncFailureReport`, passes both counts to the reducer, and lists the stuck rows by name in the
sync detail, each with a **Retry**. No schema, migration or contract change. It touches sync, so the
architect escalates the PR to Jon.

Ports Yes Chef's effort of the same name (`yes-chef/docs/efforts/sync-failure-surfacing.md`, Slice 2,
device-passed 2026-10-26). The package work is done: jon-platform #72, #82, #83 and #84 shipped the signal,
the `.needsAttention` reducer case, `requeue`, and the false-positive fixes Yes Chef's first device pass
found (the whole library reading "not synced"; rows rewritten with unchanged values). Read that brief's
"Why the status can't see it today" before starting: it explains why the metadatabase, not the CloudKit
error, is the signal.

**Why now.** Galavant moved to CloudKit Production on 2026-10-08, the same move that left Yes Chef with
rows that never uploaded while its row said "Up to date". The M5 gate (Jon and Wendy, two phones, changes
both ways) is next, and it only means something if the indicator is honest.

## Today

- `GalavantCloudSync.makeSyncEngine` (`GalavantSchema/GalavantCloudSync.swift`) lists the 25 synced tables
  inline. Nothing builds a `SyncedTables` value.
- `Galavant/Settings/SyncHealthModel.swift` builds `SyncHealth` from the gate, the account, the engine's
  running and fetching state, and the pending count. `notUploadedCount` and `notAppliedCount` take their
  `0` defaults.
- `Galavant/Settings/SyncStatusSection.swift` already renders `.needsAttention` (dot, detail line,
  explanation) in `SyncStatusSection` and `SyncStatusDetailView` (#176).

## 1. One table list, and the facade forwards

- `GalavantCloudSync.syncedTables: SyncedTables` lists the same 25 types. `makeSyncEngine` keeps its
  inline list (the initializer takes variadic types), and a test asserts the two match, so a table added
  to one and not the other fails the tests. Compare `syncedTables.recordTypes` with the engine's types'
  `tableName`s.
- Forward `syncFailureReport(in:isEngineRunning:isSendingChanges:isFetchingChanges:now:verdictCache:)` and
  `requeue(recordType:primaryKeys:in:verdictCache:)` with `tables: syncedTables` filled in, as Yes Chef's
  `YesChefCloudSync` does. Keep the package's default grace period (30 minutes).

## 2. The model feeds the counts

- In `refresh()`, when the gate is on and the engine is running, call the report with
  `isSendingChanges: syncEngine.isSendingChanges` and `isFetchingChanges`. The package returns empty
  counts while a batch is in flight, so a send or fetch never counts. Otherwise, there's no report and both
  counts are zero.
- Hold the `SyncFailureVerdictCache` for the model's lifetime and store the cache each result returns.
- A thrown report sets its own error, shown through `lastError` after any start error
  (`lastStartError ?? reportError`). Clear it on the next successful report.
- The report reads the metadatabase off the main actor (`database.read`). Don't call it at launch; the
  existing refresh triggers (appear, scene active, `DatabaseChange`, end of a sync cycle) are enough.
  Coalesce overlapping refreshes so a burst of `DatabaseChange` events doesn't stack scans. Yes Chef's
  `refreshRequestedWhileRefreshing` is the pattern.

## 3. Name what's stuck, with Retry

- **The naming is pure and lives in `GalavantSchema`** (fat-model rule): a value type that takes a
  `SyncFailureReport` plus the names it needs and returns display rows (`recordType`, `primaryKeys`,
  `title`, a stable `id`). Yes Chef keeps this in its 660-line `SyncHealthModel`; don't copy that shape.
  The model only does the database read for the names and calls the pure builder.
- Titles: `ideas` → the idea's name; `trips` → the trip's name; a row with an `ideaID` → that idea's name
  plus what it is ("Photo for Tivoli", "Tag on Tivoli"); a row with a `tripID` → the trip's name plus what
  it is ("Stay in Denmark", "Document in Denmark"). Group a parent's child rows into one row when they share
  a title. Anything else, or a row whose parent can't be found, falls back to "N <table> rows" under a
  readable table name. Never show a bare UUID.
- `SyncStatusDetailView`, under `.needsAttention`, lists the rows. Each gets a **Retry** that calls
  `requeue` for that row's keys, shows progress while it runs, then refreshes. A failed retry shows its
  error under the list. Show the not-applied count as a single line ("N changes from iCloud couldn't be
  saved here"). The package can't name those rows.
- No automatic retry loop.

## Out of scope

- Yes Chef's later diagnostics: the failure diagnosis readout, the leftover-records check and its delete.
  Bring them over only if Galavant's device pass turns up rows the report can't explain.
- Moving the app-side wiring into `CloudSyncKit`. Galavant is its second consumer; record that in
  jon-platform's `SEAM-LEDGER.md`, don't lift it here.

## Tests

**Library** (`GalavantLibrary`):
1. `syncedTables` matches the engine's table list (§1).
2. The display-row builder, from a `SyncFailureReport` and a fixture of names: idea and trip titles, child
   rows titled and grouped by parent, a missing parent falls back to the count row, an unknown table falls
   back to the count row, and nothing renders a UUID.

**App** (`GalavantTests`), if the model's report call can be driven without a live engine: the counts reach
`health`, and a report error surfaces through `lastError` without overwriting a start error. Otherwise say
so in the PR and rely on the device pass.

## Done when

- One PR on branch `effort/sync-failure-surfacing`. `scripts/check-drift.sh` is green and headless
  `GalavantTests` pass. Built against jon-platform `main` (local path; no package version to bump).
- No schema, migration, sync-contract or identifier change.
- The completing PR:
  - adds a DONE-LOG entry;
  - marks this brief Done in `docs/efforts/README.md`;
  - adds to `docs/device-passes.md` under **Verification gates**: *on both phones and the iPad, Settings →
    Sync reads "Up to date" on the real library (any count here is a finding: report it, don't retry it
    away). Then, in Airplane mode, edit an idea and wait past 30 minutes: the row reads "1 item hasn't
    synced" and the detail names the idea. Turn the network back on: it uploads and returns to "Up to
    date", with or without Retry. The not-applied count is zero, or the detail says what's stuck;*
  - sets `docs/NEXT_UP.md` to exactly this block:

    ```
    # Next Up — Keep what Chat said around its places; Find on Map from Ruled out

    **Slices:** effort `seed-handoff-cleanups` (one PR, branch `effort/seed-handoff-cleanups`)
    **Briefs:** `docs/efforts/seed-handoff-cleanups.md`
    **Done when:** per the brief's "Done when"; verification per `docs/verification.md`.
    **Owed:** carry over the current **Owed:** line unchanged.
    **Notes:** ADR-0048 follow-ups. No schema or contract change. Keep the note extraction pure, in
    `GalavantSchema`. Start from a fresh `main`.
    ```
