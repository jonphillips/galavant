# Effort — Don't get killed holding the database lock

**Status:** Ready · **Summary:** TestFlight 0.2.0 (2) was killed at launch with `0xdead10cc`
(RunningBoard): iOS suspended it while it held a lock on the App Group SQLite store. Galavant has no
suspension handling. Make the app and the share extension release the store before they're suspended
and resume it when they come back, and protect the launch bootstrap with a background-time assertion.
No schema, migration, sync-contract or UI change.

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

## 2. The app posts suspend and resume

- Post `Database.suspendNotification` when the app is about to be suspended, and
  `Database.resumeNotification` when it comes back. Put this in one small, injectable piece of the app
  target that the delegates call, not in views. Cover:
  - scene → background (`sceneDidEnterBackground`) and the expiration handler of any background task
    from § 3: **suspend**.
  - scene → foreground (`sceneWillEnterForeground`): **resume**.
  - every background-mode entry point that touches the store, including
    `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` if SQLiteData's engine routes
    pushes through the app delegate. Find out how it receives them and say how in the PR: **resume** on
    entry, then **suspend** again before calling the completion handler.
- A background launch never gets a "did enter background" callback, so § 3 is what covers the crash
  above. § 2 covers the lock being held at a normal backgrounding.

## 3. Hold background time across the launch bootstrap

- Wrap the bootstrap in `GalavantApp.init()` (migrate + `makeSyncEngine`, whose trigger setup is the
  write that was in flight) in a background-time assertion. If it expires, post `suspendNotification`
  so the lock is released before iOS kills the process. Prefer
  `ProcessInfo.processInfo.performExpiringActivity(withReason:)` if `UIApplication.shared` isn't safe
  to use from `App.init`. Say which you used, and why, in the PR.
- If a write is interrupted by suspension during bootstrap, it must **not** reach the `try!`. Treat
  `SQLITE_INTERRUPT` / `SQLITE_ABORT` from sync-engine setup like the existing "CloudKit sync
  unavailable" path (`reportIssue`, stay local-only for this launch) and retry the engine setup on the
  next resume. Migration failures still fail loudly as today. Don't widen what's caught.
- Measure how long the launch bootstrap takes on a real store with a signpost or log line around
  migrate and `makeSyncEngine`, and put the number in the PR. If trigger setup is a large share of it,
  note that in the PR as a question for the architect. Don't restructure SQLiteData's setup here.

## 4. The share extension

- The extension writes to the same store and can be suspended when the host app goes away. Make it
  observe suspension too (§ 1 covers its bootstrap), and post `suspendNotification` right before
  `completeRequest` and on any cancel or dismissal path. It never needs to resume.

## Tests

**Library** (`GalavantLibrary`):
1. The live-store configuration has `observesSuspensionNotifications == true`. Test, preview and
   restore-candidate configurations don't. Pull the configuration choice into a pure function if that's
   what makes this testable.
2. Sync-engine setup that throws `SQLITE_INTERRUPT` or `SQLITE_ABORT` degrades to local-only without
   throwing out of `bootstrapDatabase`. A migration error still throws.

**App:** compile only. Suspension timing can't be unit-tested.

## Done when

- §§ 1–4 are in, tests 1–2 pass, the build is green, and the PR states the measured bootstrap time and
  how remote pushes reach the app.
- No schema, migration or sync-contract change.

## Device gate (Jon, not executor)

Recorded in `device-passes.md`: after the next TestFlight build, no new `0xdead10cc` in
`testflight --feedback` for a week of normal use, including background pushes from Wendy's edits.
