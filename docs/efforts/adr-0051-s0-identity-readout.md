# Effort — ADR-0051 Slice 0: the iCloud identity readout

**Status:** Ready (2026-10-30) · **Summary:** a read-only section in Settings →
Planners that shows this device's iCloud user record name and every travel-party share participant's
record name, name, lookup info, role, permission and acceptance status, and says whether this device
appears in the share. It ships in a TestFlight build so Jon and Wendy can each read it on their own
phones, on Production. Their readings answer ADR-0051 OQ1–OQ3 before Slice 1 adds the schema. No schema,
migration, sync or contract change, and no writes of any kind.

Implements [ADR-0051](../decisions/0051-planner-identity-from-icloud.md) § Slices, Slice 0. Read the ADR's
Context and open questions first: this slice exists only to answer them.

## Today

- Settings → Planners (`PlannerManagementView` / `PlannerManagementModel`) lists planners, rename,
  delete and **This is me**. Nothing reads CloudKit identity.
- The party is shared with `syncEngine.share(record:)` from `SettingsModel.shareTravelPartyButtonTapped`.
  Don't call that here: it re-saves the share, which only the owner may do.
- SQLiteData stores the share on the party's metadata row:
  `SyncMetadata.find(travelParty.syncMetadataID)`, column `share` (`CKShare?`).

## 1. A CloudKit-free value type, in `GalavantSchema`

- `ICloudIdentityReadout` (plain values, no `import CloudKit`, like `SyncHealth`): this device's record
  name (or why it's missing), whether the share came from the server or the stored copy, and a list of
  participants. Each participant has a record name (optional), a formatted name (optional), lookup info
  (email or phone, optional), role (owner, participant, other), permission, acceptance status, whether it
  has an iCloud account, and whether CloudKit marks it as the current user.
- A pure function decides, per participant, **"Matches this device"**: its record name equals this
  device's, or it's the current user and its record name is the `__defaultOwner__` placeholder (show both
  facts, don't hide the placeholder). A summary line reads "This device is in the share as <name>", or
  "This device isn't in the share", or "This device appears only as the owner placeholder".
- `text` renders the whole readout as plain lines for **Copy**.

## 2. Reading it, at the app boundary

- On appear, and on a **Refresh** button:
  - this device: `CKContainer(identifier: GalavantCloudSync.containerIdentifier).userRecordID()`; on error,
    show the error text;
  - the share: read the party's `SyncMetadata.share`. If there is one, fetch the fresh share by its
    record ID from the private database when this device owns the zone
    (`zoneID.ownerName == CKCurrentUserDefaultName`), otherwise from the shared database. If the fetch
    fails, use the stored copy and say so;
  - map `share.participants` (and `currentUserParticipant`) into the value type.
- No share: say "The travel party isn't shared".
- Read only. Never save, modify or accept anything.

## 3. The section

- In Settings → Planners, an **iCloud identity** section below the planner list: the summary line, this
  device's record name, then one row per participant (name, role and status; record name and lookup info
  as secondary text, selectable). Long record names wrap; don't truncate them.
- **Copy** puts `text` on the pasteboard, so Jon can paste each phone's reading into the ADR.
- In Release builds too: the whole point is reading it on TestFlight.

## Tests

**Library** (`GalavantLibrary`): the match rule (equal names; the current user under the placeholder; no
device record name; no share), the summary line for each case, and `text` (every participant's fields
present; a missing name or lookup info shown as "—", never dropped).

## Done when

- One PR on branch `effort/adr-0051-s0-identity-readout`. `scripts/check-drift.sh` is green and headless
  `GalavantTests` pass.
- No schema, migration, sync-contract or identifier change, and no CloudKit writes.
- The completing PR:
  - adds a DONE-LOG entry and marks this brief Done in `docs/efforts/README.md`;
  - adds to `docs/device-passes.md` under **Verification gates**: *after the next TestFlight build, on
    Jon's phone and on Wendy's: Settings → Planners → iCloud identity → Copy, and send both readings to the
    architect, who records OQ1–OQ3 in ADR-0051. Wendy only reads; nothing here changes the share;*
  - sets `docs/NEXT_UP.md` to the empty ticket, carrying the **Owed:** line over unchanged. Slice 1's
    brief is written after the readings.
