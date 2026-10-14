# Production Cutover Runbook

**Purpose.** The ordered, reversible steps for moving Galavant from development builds on CloudKit
**Development** to TestFlight builds on CloudKit **Production**, carrying Jon's library across and then
sharing the travel party with Wendy. This is ADR-0049 S2, the runbook for
[ADR-0049](decisions/0049-backup-restore-and-production-cutover.md) D3. Read the ADR first for *why* the
order is what it is. The model is Yes Chef's `docs/PROD-CUTOVER.md` (ADR-0056).

**Status (2026-10-08): Phases 1–5 done; Phase 6 open.** Galavant runs from TestFlight on CloudKit
**Production**. Jon's iPhone carried the library across, and a fresh iPad install pulled it down from
Production and syncs. Backup and restore worked during the run. Two things weren't recorded: whether
Production seeded in place before a restore (**OQ2 is still open**, see Phase 4b), and the dashboard
record counts in Phase 5. Next is Phase 6: Wendy installs, accepts the travel-party share, and the M5
gate runs on two phones. The **After the cutover** rules at the bottom now apply to every build.

**Not a dispatch.** These are ops steps Jon runs, with the architect, each gated on the one before. Nothing
here is Codex work. If a step turns up a code change (a schema leftover that has to go, an entitlement
fix), stop: it becomes a normal reviewed slice, and the runbook resumes after it merges.

**The spine.** The local store carries across the update in place, because the bundle id and app group
stay the same. The **Production private zone starts empty and may not seed itself**: the sync metadatabase
is keyed by container id, not environment, so it can report every row as already synced (to Development)
and upload nothing. **The known-good re-seed is restore**, which starts the device as a fresh sync peer and
re-pushes the whole library as authoritative. In-place seeding is an optimization this run may confirm
(ADR-0049 OQ2), never an assumption.

---

## Preconditions

- [x] **ADR-0049 S1 has shipped and passed on device** (D3 step 1): export on iPhone, restore on iPad,
      contents match, sync held, confirmed re-enable, undo. Merged in #157, device pass 2026-10-07.
- [x] `main` is green: `scripts/check-drift.sh` plus headless `GalavantTests`.
- [x] **No identifier changes.** The bundle ids (`com.jonphillips.galavant`, `com.jonphillips.galavant.share`),
      the container (`iCloud.com.jonphillips.galavant`) and the app group (`group.com.jonphillips.galavant`)
      stay as they are. The local carry depends on all of them.
- [ ] App Store Connect has the Galavant app record, and both Jon's and Wendy's Apple IDs are internal
      TestFlight testers (ADR-0005).
- [ ] **Ask Yes Chef first.** If Yes Chef has run its ADR-0056 Phase 4 dry run, its answer to "does
      Production seed in place?" applies here too (shared OQ, ADR-0049 OQ2). Read it before Phase 4.
- [ ] A window with slack. The first Production push carries every image as a `CKAsset` and may be
      throttled.

---

## Phase 1: Audit the Development schema *(D3 step 2)*

Deploying is permanent: record types and fields can be added to Production later, never removed. So
compare the CloudKit dashboard's **Development** schema with `GalavantCloudSync.makeSyncEngine`
(`GalavantLibrary/Sources/GalavantSchema/GalavantCloudSync.swift`, 25 tables) **in both directions**.

- [x] **Every registered table has a record type, with every column as a field.** Development creates
      types and fields only when a record carrying them is first pushed. A table that has never held a row
      has no type yet. A column that has only ever been `NULL` has no field yet. Production does not infer
      schema, so saves that need a missing type or field fail there. Check recent additions first
      (`tripDocuments`, `ideaEvaluations`). **Fix:** on a development build with sync on, create a row
      that fills the missing column, let it push, check the dashboard, then delete the row.
      **Exception: a gap that nothing in the build can write is fine to leave.** Deploys are additive, so it
      goes to Production with the slice that first writes it. Today that's `travelProfiles`: the storage
      and editor exist, but no screen presents the editor (M6-EXECUTION item 4), so it probably has no
      record type yet. Note it and move on.
- [x] **Nothing extra.** A record type or field with no registered table or column is a leftover from an
      experiment. Delete it from the Development schema in the dashboard before deploying. **Never use
      "Reset Development Environment"**: it deletes all Development data, and that data is the rollback.
- [x] **No local-only table leaked.** Tables that aren't registered with the engine (for example
      `TripTravelModeOverride`, ADR-0043) must have no record type.
- [x] **No squash.** Galavant doesn't adopt Yes Chef's migration squash (D3 step 2). If the audit finds a
      dead column that has to be dropped first, stop and take it back to the architect.
- [x] **Indexes for Phase 5.** Add a Queryable index on `recordName` for the types you'll count:
      `travelParties`, `ideas`, `trips`, `tripIdeas`, `imageAssets`, `tripDocuments`. Indexes deploy with
      the schema, so the Production Records query works too.

**Gate:** both directions are clean. Note any fixes for the DONE-LOG entry at the end.

---

## Phase 2: Deploy the schema to Production *(D3 step 3)*

- [x] In the CloudKit dashboard, **Deploy Schema Changes** from Development to Production. This replaces
      the old `device-passes.md` item to promote `tripDocuments`.
- [x] Spot-check that Production now lists the same record types as Development.

**Gate:** Production's schema matches the audited Development schema.

---

## Phase 3: Take the re-seed backup *(D3 step 4)*

- [x] **Stop editing on every device from here on.** Anything changed after the backup isn't in it.
- [x] On Jon's iPhone (current development build): Settings → Backup → **Export a Backup**. The file is
      `Galavant-Backup-YYYY-MM-DD.sqlite`.
- [x] **Verify it opens without changing anything.** On the iPad development build, tap **Restore from a Backup**, pick
      the file, and wait for the **Restore This Backup?** confirmation, then tap **Cancel**. The
      confirmation only appears once the kit has copied, validated and migrated the file.
- [x] Keep the file in **two places off the phone** (for example iCloud Drive and the Mac). **This file is
      the re-seed source and the rollback.**

**Gate:** a backup that has been checked exists in two places.

---

## Phase 4: The distribution build, installed over the development build on Jon's iPhone *(D3 step 5)*

**4a. Build checks.**
- [x] Archive a **Release** build and upload it to TestFlight.
- [x] No development scaffolding: `--seed-demo` and `--reset-identity` are `DEBUG`-only
      (`DemoFixtures`, `IdeasListModel`), and neither scheme argument is enabled.
- [x] Sync enablement goes through the persisted `GalavantCloudKitSyncEnabled` key (Settings → sync), not
      the `-GalavantCloudKitSyncEnabled` launch argument.
- [x] **Entitlements in the exported build.** Check both `Galavant.app` and `GalavantShare.appex` with
      `codesign -d --entitlements - <bundle>`. Both need the app group and the iCloud container. The app
      also needs `aps-environment` = **`production`**. `project.yml` pins `development`, and the App
      Store export normally rewrites it. If it still reads `development`, Production change pushes won't
      arrive and the other device only catches up when the app comes to the foreground. Fix that before
      going on.

**4b. Install and observe in-place seeding.**
- [x] Install the TestFlight build over the development build on Jon's iPhone. Confirm the **local library
      is intact**: trips, ideas, images, documents.
- [ ] **Sync is already on after the update.** The enable key lives in the app's defaults, which carry
      over, so the engine starts against the empty Production zone on first launch. That *is* ADR-0049's
      optional in-place seeding test. Leave it a few minutes, then check Production record counts
      (Phase 5).
  - **If Production has the whole library:** in-place seeding works, so skip 4c. Record the answer to OQ2.
  - **If it is empty or partial** (the expected case): do 4c.
  - **Run 2026-10-08: not recorded.** Production ended up holding the library, but the run didn't record
    whether it seeded on its own or needed 4c, so it doesn't settle in-place seeding. OQ2 stays open,
    and Yes Chef's ADR-0056 dry run (OQ1) can still answer it.

**4c. Re-seed by restore.**
- [ ] Settings → Backup → **Restore from a Backup**, choosing the Phase 3 file. Sync is then held by the restore.
- [ ] Turn sync back on through its **Turn On iCloud Sync?** confirmation. The whole library re-pushes into Production as
      authoritative.
- [ ] **Expect throttling** (CloudKit 429s) during the first push. Don't intervene, reinstall or wipe. Let
      it drain, and watch the sync-health section until it reports no pending changes.

---

## Phase 5: Confirm Production holds the library *(D3 step 6)*

- [ ] **Server side, not the in-app indicator.** In the dashboard, query the Production **private
      database**, custom zone `co.pointfree.SQLiteData.defaultZone`. Compare the counts for the Phase 1
      types with what the iPhone shows.
- [x] **A fresh device pulls everything.** On Jon's iPad, delete the development build (its copy is still
      in the Development zone and the Phase 3 backup), install the TestFlight build, turn on sync, and
      confirm the whole library arrives, images and documents included.

**Gate (the real one):** both checks pass. Only now is the cutover real.

**Run 2026-10-08:** the fresh iPad pulled the library from Production, and it syncs. The dashboard
counts weren't recorded.

---

## Phase 6: Share with Wendy, then the M5 gate *(D3 steps 7–8)*

- [ ] **Wendy is an internal TestFlight tester** (the last unchecked precondition above).
- [ ] **Wendy's phone carries nothing.** If it has ever run a development build, she deletes Galavant
      first. Then she installs from TestFlight and turns on sync.
- [ ] Jon shares the travel party from Settings. The share is created fresh in Production. Wendy accepts.
- [ ] **The M5 gate,** on Production with both phones: share acceptance, changes both ways (create, edit,
      delete), an image round trip, and a pinned reservation keeping its date. The checklist is in
      `docs/milestones/M5-EXECUTION.md`.

---

## Rollback

- **Until Phase 5 passes**, the Development environment and its data are untouched. Reinstall a
  development build on the iPhone. If its library looks wrong, restore the Phase 3 backup there and
  re-enable sync.
- **After the cutover**, a full restore is a two-person event once the travel party is shared: Wendy may
  have to reinstall and accept a new invite (ADR-0049 D2, OQ1). Use it for real recovery only.

---

## After the cutover

- [ ] **From now on, every TestFlight build waits on a schema deploy.** `testflight` enforces schema
      parity before archive. A slice that adds a synced table or column, or is the first to write one
      (Slice 3 writes `ideaEvaluations.evaluationDate` and `summary`; wiring `travelProfiles` writes
      that table), must push it from a development build and deploy the schema to Production before
      its TestFlight build goes out.
- [ ] Keep the **Development** zone as a cold archive at least until the M5 gate has passed on Production.
- [x] Record the answer to **OQ2** (did Production seed in place?) in ADR-0049, and tell Yes Chef
      (ADR-0056 OQ1). Check the trigger on the jon-platform `SEAM-LEDGER.md` row for the Dev→Prod
      cutover: Galavant reaching this point is half of it. *(2026-10-08: OQ2 recorded as unmeasured,
      so Yes Chef has nothing new to read; the ledger row notes that Galavant has cut over.)*
- [ ] `docs/DONE-LOG.md`: the cutover, with any Phase 1 fixes (Phases 1–5 logged 2026-10-08).
      `docs/device-passes.md`: clear the M5 gate when it passes. `docs/ROADMAP.md`: mark M5.
