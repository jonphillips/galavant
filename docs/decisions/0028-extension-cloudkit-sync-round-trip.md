# ADR-0028: Share-extension → CloudKit sync round-trip, and a persisted-local enablement gate

*Status: accepted — 2026-07-01. Ports YesChef's device-verified M4 sync milestone;
source of truth is jon-platform `docs/ios/persistence-and-sync.md`.*

## Context

Galavant captures ideas from a share extension that writes directly to the app-group
SQLite store (ADR-0020). The main app owns a `SyncEngine`; the extension was bootstrapped
**local-only** on the theory that "the main app will push the new idea on its next run."

That theory is wrong on this stack, and the extension→CloudKit path had in fact never
worked. YesChef's M4 milestone — the first fully device-verified extension→CloudKit
round-trip on SQLiteData+CloudKit — surfaced *why*, in a chain of failures no unit test
covers. Galavant sat in the exact pre-debugging state. This ADR records the fixes; the
mechanics live in the house doc, not here.

## Decision

**The extension is a second writer that must construct a *stopped* `SyncEngine`, and the
consumer side must actively drain what it leaves behind.** Four coupled changes:

1. **Extension constructs the engine, stopped ("construct, don't run").** A new
   `bootstrapDatabaseForShareExtension()` builds the engine with
   `startImmediately: false`. Constructing it is what makes SQLiteData install its sync
   *triggers*, so the extension's write gets `SyncMetadata` **and** a
   `PendingRecordZoneChange` row. The prior local-only bootstrap skipped construction
   entirely, so captures got neither and never left the device. The extension still never
   `start()`s or networks.

2. **The extension carries the iCloud container entitlement (CloudKit law 6).**
   `SyncEngine.init` eagerly builds `CKContainer` even when stopped; without the container
   entitlement that raises an **Objective-C exception a Swift `do/catch` cannot catch** →
   hard crash (a blank, hanging share sheet). `GalavantShare.entitlements` gains
   `com.apple.developer.icloud-container-identifiers` + `icloud-services`. It does **not**
   gain `aps-environment` — the extension installs triggers, it never pushes.

3. **`completeRequest` waits for the pending change to be durable.** With the engine
   stopped, SQLiteData defers persisting the `PendingRecordZoneChange` to a
   fire-and-forget `Task`; a share extension calls `completeRequest` the instant its
   write returns, and the host tears the process down before that `Task` commits — the row
   lands locally but its pending change is lost. `CaptureModel.save` now snapshots the
   pending count before the write and bounded-polls
   `sqlitedata_icloud_pendingRecordZoneChanges` until it grows (short timeout, then
   proceeds so a save never hangs) before the sheet completes.

4. **The app re-drains on scene activation.** The pending table drains **only** inside
   `SyncEngine.start()`, and a running engine never re-reads it (it pulls from its own
   in-memory state). The common path — app live, backgrounded while the share sheet is up,
   then foregrounded — never calls `start()` again, so the extension's rows sit undrained.
   `AppContainer` now cycles `stop()`+`start()` on scene `.active` when the pending count
   is `> 0`, gated on the count so it fires only right after a share.

**Sync is gated behind persisted-local enablement, and turned on last.** Per the house
doc's rollout law, the engine is constructed stopped and started only via
`GalavantCloudSync.startIfManuallyEnabled()`, which checks an opt-in flag **and**
`CKAccountStatus`. The opt-in is a `UserDefaults` key (`GalavantCloudKitSyncEnabled`), not
a bare launch-arg: a launch-arg lives only in the volatile `NSArgumentDomain` and vanishes
on any non-Xcode relaunch (icon tap, hand-back from the extension), so the engine would
silently never start and the extension's rows would pile up undrained — the "enablement
trap." The dev launch-arg (`-GalavantCloudKitSyncEnabled`) is mirrored into the persistent
key at app `init()`. This replaces the app's prior unconditional immediate start.

All of this lives in a new `GalavantCloudSync` enum in `GalavantSchema` (the mirror of
YesChef's `YesChefCloudSync`): the gate, `makeSyncEngine`, `startIfManuallyEnabled`, the
scene-active redrain, and the pending-change poll.

## Consequences

- Sync is **off by default** until the gate is flipped — a deliberate pre-GA posture, not
  a regression. Rollout is: exercise in CloudKit Development → deploy schema Dev→Prod
  (one-way) → wipe local → remove the gate.
- **Device round-trip is the definition of done, and is still outstanding.** No unit test
  covers the process-teardown race in change 3 or the drain-only-in-`start()` fact in
  change 4; a green suite is necessary but nowhere near sufficient. Verification means:
  enable the gate, capture on-device via the extension, and confirm the idea appears on a
  second device / in the CloudKit Dev dashboard Records list — never by a send-cycle log
  line.
- The ground-truth diagnostic if it misbehaves: compare
  `count(*) FROM sqlitedata_icloud_pendingRecordZoneChanges` against
  `count(*) FROM sqlitedata_icloud_metadata WHERE lastKnownServerRecord IS NULL` in the
  attached metadatabase (the hidden `.<db>.metadata-<container>.sqlite` sibling). Matching
  non-zero counts ⇒ producer side works, records are simply never drained.

## Why this is an ADR and not just a bug fix

It encodes general laws of this stack, inherited by every future app extension and every
synced write: **an extension writer must construct a stopped engine and carry the iCloud
entitlement; a stopped-engine write is not durable until its pending change is persisted;
the pending table drains only in `start()`; and the sync enablement flag must be
persisted-local, never launch-arg-only.** Extends ADR-0001 (CloudKit, no server) and
ADR-0007/0008 (the CloudKit sharing/uniqueness laws) with the extension-writer and
rollout laws.
