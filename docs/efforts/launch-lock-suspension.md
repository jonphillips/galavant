# Effort — Don't get killed holding the database lock

**Status:** Ready · **Summary:** TestFlight 0.2.0 (2) was killed at launch with `0xdead10cc`
(RunningBoard): iOS suspended it while it held a lock on the App Group SQLite store. Galavant has no
suspension handling. Make the app and the share extension release the store before they're suspended
and resume it when they come back, and protect the launch bootstrap with a background-time assertion.
No schema, migration, sync-contract or UI change, but the sync engine now stops when background time runs out and it's quiet (§ 2).

Evidence: TestFlight crash submission `AO5RTPQ8jcuDxz8g0jgndtM` (2026-10-29, iPhone18,1, iOS 27.2). The
log is local to the architect's checkout and isn't committed. Mechanism per GRDB's `DatabaseSharing`
article, § "How to limit the 0xDEAD10CC exception".

## What the crash shows

- `Termination Reason: RUNNINGBOARD 0xdead10cc`, `EXC_CRASH (SIGKILL)`. The process was killed, not
  faulted: thread 0 was busy doing ordinary work in `malloc`.
- Thread 0 is still in `GalavantApp.init()` → `prepareDependencies` → `bootstrapDatabase()` →
  `GalavantCloudSync.makeSyncEngine` → `SyncEngine.setUpSyncEngine()` → `UserDatabase.write` → the
  `createTriggers` / `afterUpdate` trigger setup, **inside a write transaction** on the main thread.
- The store lives in the App Group container (`GalavantStorage.liveDatabaseURL()`,
  `GalavantSchema/Database.swift`), which is exactly the case iOS kills for. `project.yml` turns on
  `UIBackgroundModes: [remote-notification]`, so a CloudKit push can launch the app straight into the
  background with a short budget. A foreground launch the user leaves at once hits the same window.

## Today

- `bootstrapDatabase(path:syncMode:)` builds a `Configuration` with only `prepareDatabase` (attaches
  the metadatabase). No `observesSuspensionNotifications`.
- Nothing posts `Database.suspendNotification` / `resumeNotification`. Nothing calls
  `beginBackgroundTask` or `ProcessInfo.performExpiringActivity`.
- `GalavantApp.init()` runs the bootstrap synchronously under `try!`. `AppDelegate` only supplies the
  scene configuration. `SceneDelegate` only accepts shares.
- The share extension (`GalavantShare/ShareViewController.swift`) bootstraps the same store in
  `viewDidLoad` via `bootstrapDatabaseForShareExtension()` and writes the captured idea to it.

## 1. Every writing process observes suspension

- In `bootstrapDatabase(path:syncMode:)`, set `configuration.observesSuspensionNotifications = true`
  when the store is the **live shared store** (the `context == .live` branch with no explicit `path`
  override, or `liveDatabasePath()`). Leave test, preview and restore-candidate databases alone.
  Restore candidates are private files, and a suspended test database would only add flakiness.
- Read GRDB's article first. A suspended database throws `SQLITE_INTERRUPT` / `SQLITE_ABORT` on writes,
  but WAL reads keep working.

## 2. Never suspend a database a sync engine may be writing to

*Amended twice on 2026-11-04, answering the questions on #197. The first version said to suspend on background and
bracket remote pushes, but pushes can't be bracketed. The second said to stop the engine and then suspend, but `stop()`
doesn't quiesce anything. Source references are to the pinned SQLiteData 1.6.6. Upstream main has the same shape.*

**Why.** SQLiteData's `CKSyncEngine` delegate receives events itself. Neither the app nor SQLiteData has a
`didReceiveRemoteNotification`, so nothing can resume the database before an event arrives. And
`handleFetchedRecordZoneChanges` and `handleStateUpdate` both wrap their writes in `withErrorReporting`, so a write
that hits a suspended database fails quietly and `handleEvent` returns normally.

Records are lost only if two things happen: a fetched batch fails, **and a later state save succeeds**. `start()` builds
new engines from the state saved in the database, so if no later save lands, the new engine fetches that batch again.
A kill is the better failure: its transaction rolls back and the engine refetches from its saved state.

**`stop()` doesn't make this safe by itself:**

- It only replaces the stored engines with an empty `SyncEngines`, and doesn't cancel or await anything. A running
  `handleEvent` keeps its engine and can carry on writing, and nothing checks that the engine is still the current one.
  Apple's header promises serial delivery, but says nothing about what releasing an engine does. A stale engine could
  therefore save its state after a resume, which is the second half of the loss.
- It doesn't cancel the start task. `uploadRecordsToCloudKit` adds pending rows to whichever engines are stored, which
  after `stop()` is none, then deletes the rows. Stopping mid-start on a writable database loses the share extension's
  captures.
- The app can't reach anything stronger. `syncEngines` is `package`, so `cancelOperations` is out of reach, and its
  header says operations can still complete afterward anyway.

**The rule:** suspend only when the engine is quiet. Otherwise leave the engine and the database alone, and accept the
chance of a kill. Quiet means `!syncEngine.isSynchronizing` and no start in flight. When quiet, the order is still
**stop the engine, then suspend** and **resume, then start the engine**.

Put this in one small injectable piece of the app target, driven by a pure plan in `GalavantLibrary` (see Tests):

- **The app enters the background:** begin a background task, and do nothing else. The engine keeps running, so an
  edit made just before leaving still uploads and in-flight writes finish. If `beginBackgroundTask` returns `.invalid`,
  treat it as expiration straight away.
- **That task's expiration handler, quiet:** `syncEngine.stop()`, then post `suspendNotification`, then end the task.
- **That task's expiration handler, busy:** end the task, and nothing else. Log which of the two it was, at `.notice`
  with public values.
- **The app will enter the foreground:** end any task. Post `resumeNotification` if the plan suspended. Start through
  the gate below if the plan stopped the engine or the gate denied a start. The existing redrain on activation stays.
- **A background launch:** when launch finishes in the background (`applicationState == .background`), treat it as
  entering the background. The engine catches up, then the expiration handler runs.
- **A push that thaws a suspended process:** after a quiet expiration nothing happens, because the engine is stopped,
  and it catches up from its saved state on the next foreground. After a busy one the engine is still running on a
  writable database, as it does today. **Don't add a remote-notification delegate.**

Use `UIApplication.didEnterBackgroundNotification` and `willEnterForegroundNotification`, **not** scene callbacks: on
iPad, one window going to the background doesn't mean the app is about to be suspended.

**One gate for every start.** `startIfManuallyEnabled` awaits the account status and then calls `start()`, and `start()`
awaits the whole start task, so without a gate a start can land after suspension. Launch (`GalavantApp.init`),
`SyncHealthModel.start`, redrain and this controller all go through one gate, checked after the account status and right
before `syncEngine.start()`:

- If background time has expired, it doesn't start, and it records that so the foreground starts instead.
- Otherwise it counts a start as in flight until `start()` returns. That count feeds the quiet check.
- Redrain's stop waits for a start in flight. That race exists today: a cold launch after a share can stop the engine
  between the add and the delete above. This comes from reading the source, not from reproducing a loss.

The seam is an optional `startSyncEngine:` closure on `CloudSync.startIfManuallyEnabled`, matching the one redrain
already has. That's a CloudSyncKit change, so its jon-platform PR comes first and this one adopts it
(`docs/agent-collaboration.md` § Dispatches whose code lands in jon-platform). The gate's state has to be safe to touch
off the main actor, because § 3's expiration handler uses it.

**What this leaves open.** `isSynchronizing` is set from the events themselves, so a fetch that begins in the instant of
expiration can be missed. Losing records then also needs the released engine to survive the freeze and save its state
after the resume. That's narrow, but it isn't closed, and it would be silent. The real fix belongs in SQLiteData:
`handleEvent` ignoring events from an engine that's no longer stored. Galavant is on upstream 1.6.6 with no vendored
copy, so that isn't this effort. The CloudSyncKit PR adds this defect to the patched-SQLiteData row in `SEAM-LEDGER.md`.
Separately, `fetchingChangesCount` can stay above zero if a stop drops an engine between its will and did events. That
only makes later expirations in that process busy, and the log will show it.

**The trade-offs, accepted:** background sync now lasts as long as iOS's background task, about 30 seconds, and a cold
background launch still catches up. After that, another device's edits wait until this one comes to the foreground.
`UIBackgroundModes: [remote-notification]` stays, because foreground delivery and those cold launches use it. A busy
expiration can still end in `0xdead10cc` if a write is running at the moment of suspension. That's today's crash in a
much smaller window, and it loses nothing.

## 3. Hold background time across the launch bootstrap

- Wrap the bootstrap in `GalavantApp.init()` (migrate + `makeSyncEngine`, whose trigger setup is the
  write that was in flight) in a background-time assertion. If it expires, mark the § 2 gate expired, then post
  `suspendNotification` so the lock is released before iOS kills the process. The engine is constructed stopped, so
  it's quiet here. The launch start is then denied, and the next foreground starts it. Prefer
  `ProcessInfo.processInfo.performExpiringActivity(withReason:)` if `UIApplication.shared` isn't safe
  to use from `App.init`. Say which you used, and why, in the PR.
- If a write is interrupted by suspension during bootstrap, it must **not** reach the `try!`. Treat
  `SQLITE_INTERRUPT` / `SQLITE_ABORT` from sync-engine setup like the existing "CloudKit sync unavailable" path
  (`reportIssue`, stay local-only for this launch). Retry the engine setup on the next resume if that works without
  re-preparing dependencies; if it doesn't, the next launch retries, and the PR says which. Migration failures still
  fail loudly as today. Don't widen what's caught.
- Log how long migrate and `makeSyncEngine` each take, as `Logger` lines at `.notice` with public values, so a
  TestFlight build reports them on a real store. **The measurement is Jon's** (see the device gate), because the real
  store is only on his devices. Don't restructure SQLiteData's setup here.

## 4. The share extension

- The extension writes to the same store and can be suspended when the host app goes away. Make it observe suspension
  too (§ 1 covers its bootstrap), and post `suspendNotification` right before `completeRequest`, on every exit path
  (`finish()` covers both save and cancel, because `CaptureConfirmView` calls `onClose` for both).
- **Post `resumeNotification` at the start of each request,** in `viewDidLoad`. iOS can reuse the process for the next
  share (that's why `didBootstrap` exists), so without this the second share would hit a suspended database. Its engine
  is constructed stopped and never started, so the § 2 ordering doesn't apply here.

## Tests

**Library** (`GalavantLibrary`):
1. The live-store configuration has `observesSuspensionNotifications == true`. Test, preview and
   restore-candidate configurations don't. Pull the configuration choice into a pure function if that's
   what makes this testable.
2. Sync-engine setup that throws `SQLITE_INTERRUPT` or `SQLITE_ABORT` degrades to local-only without
   throwing out of `bootstrapDatabase`. A migration error still throws.
3. The pure plan from § 2: given each event and whether the engine is quiet, it returns its effects in order.
   Background begins a task and neither stops nor suspends. An invalid task runs expiration. Quiet expiration is stop,
   then suspend, then end. Busy expiration only ends. Foreground is end, then resume only if the plan suspended, then
   start only if the plan stopped the engine or a start was denied. Quiet expiration then foreground, busy expiration
   then foreground, foreground with no expiration, and a repeated event are all covered.
4. The start gate: a start after expiration is denied, and the next foreground starts. A start in flight makes the
   engine busy until it returns. Redrain's stop waits for a start in flight.

**CloudSyncKit:** `startIfManuallyEnabled` calls the injected `startSyncEngine`, and behaves as today without one.

**App:** compile only. Suspension timing can't be unit-tested.

## Done when

- §§ 1–4 are in, tests 1–4 and the CloudSyncKit test pass, the build is green, and the bootstrap timings and each
  expiration's outcome are logged.
- The CloudSyncKit PR is merged first, with the `SEAM-LEDGER.md` row widened.
- No schema or migration change, and no change to what syncs. § 2 changes only when the engine runs.

## Device gate (Jon, not executor)

Recorded in `device-passes.md`: no unexplained `0xdead10cc` over a week, catching up after the app has been in the
background, the logged bootstrap timings, and how often expiration finds the engine busy.
