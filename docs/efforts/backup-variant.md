# Effort — Backups say which build made them

**Status:** Ready · **Summary:** Pass `DatabaseBackupVariant` to CloudSyncKit's backup configuration, so a backup
records whether Galavant or Galavant Dev exported it and TestFlight Galavant refuses a Galavant Dev backup. Closes
ADR-0050 OQ2. No schema, migration, sync-contract, or UI change.

**Implements:** [ADR-0050](../decisions/0050-galavant-dev-variant.md) OQ2, answered by the marker Yes Chef added to
CloudSyncKit (yes-chef ADR-0059 D6, jon-platform #102). jon-platform `docs/ios/persistence-and-sync.md` § The Dev
variant states the rule.

## The work

1. **`GalavantLibrary/Sources/GalavantSchema/GalavantCloudSync.swift`:** inside the existing `#if DEBUG` block, add a
   `backupVariant` of `.development`, and `.production` in the `#else`. Pass it as `variant:` to
   `databaseBackupConfiguration`. Yes Chef's `YesChefCore/CloudSync.swift` is the model.
2. **Test, in `GalavantSchemaTests/DatabaseBackupTests.swift`:** the configuration declares a variant, and under the
   test build (Debug) it's `.development`.

What CloudSyncKit already does, so don't reimplement it: a snapshot stamps `PRAGMA application_id` with the variant,
and a production restore throws `developmentBackup` on a development stamp. Backups made before this change carry no
stamp (`application_id` 0), and both builds still accept them.

**Verification:** `scripts/check-drift.sh`, per `docs/verification.md`.

**Done when:** the configuration passes its variant, the test passes, and closeout runs (ADR-0005 D16), appending the
device gate below.

## Device gate (Jon)

Export a backup from Galavant Dev, then try to restore it in TestFlight Galavant: the restore is refused with the
"development backup" message. A backup exported from TestFlight Galavant still restores there.
