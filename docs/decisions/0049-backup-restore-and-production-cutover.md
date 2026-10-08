# ADR-0049: Local backup & restore, and the order of the Production cutover

*Status: **accepted** — 2026-10-06, ratified by Jon merging #154. S1 shipped in #157 and passed on device
2026-10-07. S2 is [`docs/PROD-CUTOVER.md`](../PROD-CUTOVER.md). (Drafted by the architect from a design
conversation with Jon.) Adopts jon-platform
[ADR-0006](../../../../jon-platform/docs/adr/0006-lift-backup-restore-into-cloud-sync-kit.md) (backup and
restore lifted from Yes Chef into `CloudSyncKit`, with an owner-only restore guard). Rides ADR-0001 (CloudKit via SQLiteData), ADR-0003 (one shared travel
party), ADR-0005 (TestFlight distribution), ADR-0009 (images are in-database BLOBs), and ADR-0028 (share
extension and the persisted sync switch). Prior art: Yes Chef
[ADR-0030](../../../../cooking/yes-chef/docs/decisions/ADR-0030-local-backup-and-restore.md) and
[ADR-0056](../../../../cooking/yes-chef/docs/decisions/ADR-0056-move-to-production-and-data-carry.md).*

## Context

Wendy is starting to use Galavant. Per ADR-0005 that means TestFlight, and a TestFlight build talks to
CloudKit **Production**, not the Development environment every build so far has used. That changes three
things at once:

1. **Both phones move, not just hers.** Sharing works only within one environment, so Jon's phone moves to
   TestFlight builds too.
2. **Jon's library may not follow him.** Yes Chef's cutover work established that the sync metadatabase is
   keyed by container id, not environment. After the switch it can report every row as already synced (to
   Development) and upload nothing to the empty Production zone. Restoring from a backup is the known-good
   re-seed: it starts the device as a fresh sync peer and re-pushes everything.
3. **The first Production schema deploy is permanent.** Production is additive-only: record types and fields
   can never be removed once deployed.

**Galavant has no backup today.** Jon's trips, ideas, images (BLOBs in the database, ADR-0009), and documents
live only on his devices and in the Development zone. Yes Chef has a measured, test-covered backup and restore,
and jon-platform ADR-0006 lifts it into the `CloudSyncKit` package both apps already use, so Galavant adopts it
rather than copying it.

**Galavant also shares, and Yes Chef doesn't.** The whole library hangs off one `TravelParty` root (ADR-0003)
that Jon owns and Wendy joins as a participant. A restore discards the metadatabase that records who owns each
row, so a restore on a participant's phone would probably push Jon's records into Wendy's private zone as her
own copies. ADR-0006's ownership guard is what prevents that; this ADR sets how Galavant uses it.

## Decision

### D1. Adopt `CloudSyncKit` backup and restore; no Galavant-local copy

`GalavantCloudSync` (the existing thin facade) supplies Galavant's constants and nothing more:

- display name `Galavant`, filename prefix `Galavant-Backup-YYYY-MM-DD.sqlite`;
- identifying tables `travelParties` and `ideas`;
- the live store path (`GalavantStorage.liveDatabasePath()`, in the app group);
- a migrate closure that runs Galavant's migrator on a restore candidate with sync disabled;
- the declared schema version (ADR-0006 D4; today it equals the migration count);
- a restore-hold defaults key alongside the existing sync-enable key.

A snapshot captures every table, synced and local-only (for example the ADR-0043 travel-mode overrides), and
every image byte.

### D2. Restore is for the travel party's owner

- **On a participant's phone (Wendy's today), backup and restore are hidden.** Settings says *"Backups are made
  by the person who shared this travel party with you."* Her phone holds nothing that isn't Jon's, so a
  participant backup would protect nothing and a participant restore would duplicate the library. The kit
  refuses both cases anyway (ADR-0006 D3); hiding them keeps the UI honest.
- **On the owner's phone, restore proceeds with two warnings in the confirmation:**
  - The restored library becomes the version everywhere once sync is turned back on. It overwrites iCloud,
    and anything deleted since the backup comes back (Yes Chef ADR-0030 Amd 2).
  - The travel party may need to be shared again, and Wendy may need to delete the app, reinstall, and accept
    the new invite (OQ1).
- **Turning sync back on after a restore is its own confirmed step**, as in Yes Chef. That re-enable, not the
  restore, is the act that changes iCloud.

### D3. The cutover order

The full checklist becomes `docs/PROD-CUTOVER.md` (S2), modelled on Yes Chef's runbook. The decision here is
the order and its gates:

1. **S1 has shipped** and backup and restore are verified on a development build: export, restore on a second
   device, and contents match.
2. **Audit the Development schema before deploying it.** Compare the record types and fields in the CloudKit
   dashboard against the tables `GalavantCloudSync.makeSyncEngine` registers, in both directions. Anything left
   over from an abandoned experiment becomes permanent once deployed. Galavant does **not** adopt Yes Chef's
   migration squash, because nothing here needs a dead column dropped first. Revisit only if the audit finds
   one.
3. **Deploy the schema to Production.** This includes `tripDocuments`, already flagged in `device-passes.md`.
4. **Back up from the current development build.** Verify the file opens and keep it in two places off the
   phone. That file is the re-seed source and the rollback.
5. **Install the TestFlight build over the development build on Jon's phone.** Optionally enable sync first
   without restoring, to see whether rows reach Production on their own. Otherwise restore the step-4 backup,
   then confirm and re-enable sync.
6. **Check the Production zone in the CloudKit dashboard** (record counts, not the in-app indicator). Then
   confirm a second, freshly installed Galavant on Jon's account pulls down the whole library.
7. **Only then share the travel party with Wendy.** The share is created fresh in Production. Wendy installs
   from TestFlight with nothing to carry: her phone has never held Production data, and if it ever ran a
   development build, she deletes the app first. She turns on sync and accepts the invite.
8. **That two-phone session is the M5 gate:** share acceptance, two-way changes, and image round trips, all on
   Production.

**Rollback:** until step 6 passes, the Development environment and its data are untouched. Reinstalling a
development build returns to the working library.

### D4. Non-goals

- **Restore on a participant's phone** that keeps their own rows and drops the owner's. That's ADR-0006's
  deferred case; Galavant participants have no rows of their own today.
- **Automatic or periodic snapshots** (Yes Chef ADR-0030 S3). Worth doing later, starting with a snapshot
  just before migrations run, but not needed for the cutover.
- **Portable or JSON export.** That's a separate portability goal, not durability.

## Slices

- **S1: Adopt backup and restore** *(shipped, #157)*. Galavant's facade
  configuration (D1), a Settings "Backup" section with export, restore, undo last restore, and the confirmed
  re-enable modelled on Yes Chef's rows, hidden on a participant's phone (D2). Package-level tests: Galavant's
  configuration identifies a Galavant store and rejects a Yes Chef one, and a seeded store round-trips through
  snapshot, prepare, and restore with image BLOBs intact. Device gates go into `device-passes.md` when S1
  lands.
- **S2: [`docs/PROD-CUTOVER.md`](../PROD-CUTOVER.md)** *(architect, docs only; written 2026-10-07)*: the runbook for D3, written once S1's shape is
  known.

## Consequences

- Galavant gets a durability net outside CloudKit for the first time, and the cutover gets a rollback.
- Restore takes over the M5 cutover's re-seed role. The M5 two-device share test happens once, on Production,
  rather than once on Development and again after the switch.
- Galavant inherits Yes Chef's accepted risks unchanged: restore doesn't coordinate with an in-flight
  share-extension save, and backup files are unencrypted wherever the user puts them.
- Once the travel party is shared, a full restore is a two-person event (Wendy reinstalls). It is meant for
  real recovery, not routine use.

## Open questions

- **OQ1 — After the owner restores, does the existing travel-party share survive?** The restore drops the
  root's sync bookkeeping, including its link to the `CKShare`. The re-pushed root may keep the server's share
  reference or clear it. Measure it the first time an owner restores with a live share. The D2 warning stays
  until then. (Same question as jon-platform ADR-0006 OQ2.)
- **OQ2 — Does Production seed in place, without a restore?** Shared with Yes Chef ADR-0056 OQ1. Whichever
  app cuts over first answers it for both. D3 step 5 is written to work either way.
  **2026-10-08: Galavant cut over first and didn't measure it.** Production ended up holding the library,
  but the run didn't record whether it seeded on its own or needed the restore, so it doesn't settle
  it. The question stays with Yes Chef's ADR-0056 dry run. It only matters for a future cutover. Galavant's own carry is done.
