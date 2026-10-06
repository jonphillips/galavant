# Effort — ADR-0049 S1: backup & restore

**Status:** Designed (2026-10-06). **Blocked** on the `CloudSyncKit` lift (yes-chef effort
`cloudsynckit-backup-lift`, jon-platform ADR-0006). The architect dispatches this once that merges. ·
**Summary:** [ADR-0049](../decisions/0049-backup-restore-and-production-cutover.md) D1–D2. Adopt the
`CloudSyncKit` backup and restore: Galavant supplies its constants and a migrate-by-path entry point, and
Settings gains a Backup section that only the travel party's owner sees. The cutover's re-seed and rollback
depend on it. No schema change, but it **touches sync**, so the architect escalates the PR to Jon.

Read first: ADR-0049, jon-platform `docs/adr/0006-lift-backup-restore-into-cloud-sync-kit.md`, and the
lifted API as merged in `packages/CloudSyncKit`. Yes Chef is the reference consumer: its `YesChefCloudSync`
facade, `Schema.swift` `migrateRestoreCandidate(at:)`, `SettingsViews.swift` backup rows, and
`SyncStatusSection.swift` restore-hold row.

## 1. Run the migrator against an explicit path

The kit needs a closure that migrates a restore candidate at a given URL with sync disabled. Today
`bootstrapDatabase(syncMode:)` (`GalavantSchema/Database.swift`) builds the migrator inline and opens either
the live path or SQLiteData's default.

- Pull the migration registrations into one function both paths call. **Move them; never edit a migration
  body.** The registered list and order must be byte-for-byte what runs today.
- Add `migrateRestoreCandidate(at:)` on the same model as Yes Chef's: scoped `context = .live` so SQLiteData
  honors the explicit path rather than a test-context ephemeral one, `syncMode: .disabled`, run the
  migrator, close.
- Existing bootstrap behavior for the app, previews, tests, and the share extension is unchanged.

## 2. Facade configuration (`GalavantCloudSync`)

| Value | Galavant |
| --- | --- |
| display name | `Galavant` |
| filename prefixes | `Galavant-Backup-`, `Galavant-PreRestore-`, `Galavant-Restore-` |
| identifying tables | `travelParties`, `ideas` |
| live store URL | the app-group path from `GalavantStorage`. **Restore throws if the app group is unavailable**; it never falls back to Application Support the way `liveDatabasePath()` does |
| migrate closure | `migrateRestoreCandidate(at:)` from §1 |
| declared schema version | the current registered-migration count, guarded by a test that the two match |
| restore-hold key | `GalavantCloudKitSyncRestoreRequiresManualEnablement` |
| last-pre-restore key | `GalavantDatabaseBackupLastPreRestorePath` |

App start must respect the hold: the launch-environment mirror stays suppressed while a restore holds sync
off. The kit does this; make sure Galavant's `init()` calls go through the hold-aware facade.

## 3. Settings → Backup

A new section in `SettingsScreen`, modelled on Yes Chef's rows, using the kit's export and restore models:

- **Export a backup:** `fileExporter`, default name `Galavant-Backup-YYYY-MM-DD.sqlite`.
- **Restore from a backup:** `fileImporter`, then the kit's prepare step, then a confirmation:
  - *"This replaces the library on this device. Galavant saves an automatic undo backup first. iCloud sync
    stays off until you turn it back on. When you do, this restored library becomes the version everywhere: it
    overwrites iCloud, and anything deleted since the backup comes back."*
  - When the kit reports the store holds shares, add: *"Your travel party may need to be shared again, and
    the people you share with may need to reinstall Galavant and accept the new invite."*
- After restoring, prompt to close and reopen, as Yes Chef does.
- **Undo last restore** when the kit has an undoable restore.
- **On a participant's phone the section shows only:** *"Backups are made by the person who shared this
  travel party with you."* Use the kit's foreign-owned-rows check (ADR-0006 D3), not a Galavant-side guess
  from planners.

## 4. Sync status while restore holds sync off

When sync is held by a restore, `SyncStatusSection` says so and turning sync on is a **separately confirmed**
step. Copy adapted from Yes Chef: *"This device was restored from a backup. Turning sync on uploads that
restored library to iCloud and to everyone you share with, overwriting what is there, and anything deleted
since the backup comes back. If you only wanted this device restored, keep sync off."*

## Done when

- Export and restore work end to end through the kit, with the D2 owner-only rule. Nothing restore-specific is
  re-implemented in Galavant.
- **Package tests (`GalavantLibrary`):**
  - Galavant's configuration accepts a Galavant store and rejects a non-Galavant SQLite file.
  - A seeded store with `ImageAsset` BLOBs and a `TripDocument` round-trips through snapshot, prepare, and
    restore byte-for-byte.
  - A snapshot built with an earlier prefix of the migrations is migrated forward by
    `migrateRestoreCandidate(at:)`.
  - The declared version equals the registered-migration count.
- The existing suites still pass, and the app builds.
- New source or test files are picked up by `xcodegen generate`, and `project.yml` and the `pbxproj` are both
  committed (see `docs/verification.md`).
- The completing PR adds the S1 device gate to `docs/device-passes.md` (below), adds the `DONE-LOG.md` entry,
  and sets `NEXT_UP.md` to `Nothing dispatched.` The architect then writes S2 (`PROD-CUTOVER.md`) and decides
  when ADR-0048 Slice 3 resumes.

**S1 device gate (Jon, development builds, one iCloud account):** export on iPhone to Files; restore on iPad;
confirm trips, ideas, images, and documents match; sync stays off after relaunch; re-enable asks for
confirmation; Undo last restore returns the previous library.

## Verification

Per [`../verification.md`](../verification.md). No simulator walkthroughs. Compile, run tests, and hand off.

## Out of scope

- The Production cutover itself (ADR-0049 D3, runbook in S2).
- Participant-side restore, automatic snapshots, JSON export (ADR-0049 D4).
- Changes to `CloudSyncKit`. If the lifted API is missing something Galavant needs, ask in the PR
  (`question-for-architect`) rather than patching the kit inside this effort.
