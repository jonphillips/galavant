# Effort — Don't get killed holding the database lock

**Status:** Ready · **Summary:** TestFlight 0.2.0 (2) was killed at launch with `0xdead10cc`
(RunningBoard): iOS suspended it while it held a lock on the App Group SQLite store. Galavant has no
suspension handling. Make the app and the share extension release the store before they're suspended
and resume it when they come back, and protect the launch bootstrap with a background-time assertion.
No schema, migration, sync-contract or UI change, but the sync engine now stops when background time runs out (§ 2).

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

## 2. Never suspend a database a running sync engine can write to

*Amended 2026-11-04, answering the questions on #197. The first version of this section said to suspend on
background and bracket remote pushes. Pushes can't be bracketed, and suspending under a running engine can lose
records.*

**Why.** SQLiteData's `CKSyncEngine` delegate receives events itself. Neither the app nor SQLiteData has a
`didReceiveRemoteNotification`, so nothing can resume the database before an event arrives. And
`handleFetchedRecordZoneChanges` and `handleStateUpdate` both wrap their writes in `withErrorReporting`. So a batch
that hits a suspended database fails quietly, and `handleEvent` returns normally. `CKSyncEngine`'s in-memory state has
already moved past that batch, and the next state update after a resume saves it. The records are then never fetched
again. A crash is the better failure: its transaction rolls back and the engine refetches from its saved state.

**The rule:** the order is always **stop the engine, then suspend** and **resume, then start the engine**.

Put this in one small injectable piece of the app target, driven by a pure plan in `GalavantLibrary` (see Tests):

- **The app enters the background:** begin a background task, and do nothing else. The engine keeps running, so an
  edit made just before leaving still uploads and in-flight writes finish.
- **That task's expiration handler:** `syncEngine.stop()`, then post `suspendNotification`, then end the task.
- **The app will enter the foreground:** end any task, post `resumeNotification`, then, if this controller stopped the
  engine, restart it with `GalavantCloudSync.startIfManuallyEnabled()`. The existing redrain on activation stays.
- **A background launch:** when launch finishes in the background (`applicationState == .background`), treat it as
  entering the background. The engine catches up, then the expiration handler stops it.
- **A push that thaws a suspended process:** nothing happens. The engine is stopped, so no event can arrive, and it
  catches up from its saved state on the next foreground. **Don't add a remote-notification delegate.**

Use `UIApplication.didEnterBackgroundNotification` and `willEnterForegroundNotification`, **not** scene callbacks: on
iPad, one window going to the background doesn't mean the app is about to be suspended.

**The trade-off, accepted:** background sync now lasts as long as iOS's background task, about 30 seconds, and a cold
background launch still catches up. After that, another device's edits wait until this one comes to the foreground.
`UIBackgroundModes: [remote-notification]` stays, because foreground delivery and those cold launches use it.

## 3. Hold background time across the launch bootstrap

- Wrap the bootstrap in `GalavantApp.init()` (migrate + `makeSyncEngine`, whose trigger setup is the
  write that was in flight) in a background-time assertion. If it expires, post `suspendNotification`
  so the lock is released before iOS kills the process. Prefer
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
3. The pure plan from § 2: given each event, it returns its effects in order. Background begins a task and neither stops
   nor suspends. Expiration is stop, then suspend, then end. Foreground is end, resume, then start, and it starts only if
   the plan stopped the engine. Expiration then foreground, foreground with no expiration, and a repeated event are all
   covered.

**App:** compile only. Suspension timing can't be unit-tested.

## Done when

- §§ 1–4 are in, tests 1–3 pass, the build is green, and the bootstrap timings are logged.
- No schema or migration change, and no change to what syncs. § 2 changes only when the engine runs.

## Device gate (Jon, not executor)

Recorded in `device-passes.md`: no new `0xdead10cc` over a week, catching up after the app has been in the background,
and the logged bootstrap timings.
