# ADR-0051: Planner identity comes from the iCloud account

*Status: **accepted** — 2026-10-30. Slice 0: effort
[`adr-0051-s0-identity-readout`](../efforts/adr-0051-s0-identity-readout.md). Carries out [ADR-0008](0008-second-device-identity.md) § Future
("back planner identity with the CloudKit participant"). Builds on [ADR-0001](0001-cloudkit-instead-of-custom-server.md)
("iCloud *is* the identity") and [ADR-0007](0007-attribution-and-sharing-fks.md) (single-FK sharing).
Unblocked by Wendy accepting the Production travel-party share on her own phone (the share sheet says she
joined 2026-10-18).*

## Context

"Who am I on this device" is a device-local `currentPlannerID` (app storage), set by the Ideas screen's
"Who are you?" picker or by Settings → Planners → **This is me** (#170). A `Planner` row is only a UUID and
a typed `displayName`. Three problems follow:

- **Every new device asks.** A reinstall, a new phone, or Galavant Dev next to TestFlight all start with
  no identity, and the picker is a list of first names.
- **Nothing stops a wrong pick.** Choosing "Wendy" on Jon's phone silently attributes his votes and taste
  overlay to her.
- **Duplicate planners.** Two offline devices can each create "Jon". ADR-0008 converges the party but
  leaves planner-level dedup open (`open-questions.md`, TravelParty follow-ups (2)).

CloudKit already knows who each device belongs to:

- `CKContainer.userRecordID()` gives this device's iCloud user a record name that is stable for the
  Apple ID within the container, with no permission prompt. It's an opaque key, not personal data.
- The travel party's `CKShare` (SQLiteData exposes it as `SyncMetadata.share` on the `TravelParty` row)
  lists its participants. Each has a `userIdentity` with a `userRecordID`, and, for an accepted
  participant, `nameComponents` and `lookupInfo` (the email address or phone number the invitation
  went to). The share always includes its owner and the
  current user. The old discoverability APIs are deprecated since iOS 17 and not used here.

## Decision

1. **A planner can be claimed by an iCloud user.** `Planner` gains `iCloudUserRecordName: String?`
   (nullable, synced, additive). It's the strong key; `displayName` stays the editable name the party
   uses ("Jon", not "Jonathan").
2. **A device binds itself.** At launch, with the account available and sync caught up, the device reads
   its own record name. If a planner in its party carries that name and the device has no valid
   `currentPlannerID`, it binds to that planner with no prompt. When a person picks or creates a planner
   (picker, **This is me**, create), and that planner is unclaimed, the claim is written to it.
3. **A claimed planner isn't anyone else's.** The picker marks a planner claimed by another iCloud user,
   and choosing it asks first, as **This is me** does today. Choosing it sets this device's
   `currentPlannerID` only; it never overwrites the other person's claim.
4. **Names and contact come from the share, live.** Settings → Planners shows each claimed planner's
   participant name, and the email or phone number the invitation used, as a subtitle, read from the share when it's available. They are not copied
   into synced rows; the share already holds them. A new planner's name field is pre-filled from this
   device's own participant name when there is one.
5. **One planner per iCloud user.** Two planners with the same record name (an offline race) converge to
   the lowest UUID, repointing their children, by the ADR-0008 logical-uniqueness pattern. That closes
   ADR-0008's open planner-level dedup for claimed planners.
6. **No account, no change.** Signed out, restricted, or local-only: the device keeps today's
   device-local behavior.

## Open questions (Slice 0 answers 1–3 on device, before any schema change)

- **OQ1 — Do the record names match?** Is a participant's `userIdentity.userRecordID.recordName`, as the
  *other* device sees it in the share, equal to what `CKContainer.userRecordID()` returns on that
  person's own device? The owner may appear under the `__defaultOwner__` placeholder on its own device.
  If the names don't match, Decision 1 keys on the share participant's identity instead, and the binding
  has to go through the share.
  Apple's share sheet doesn't show record names, so only Slice 0 can answer this.
- **OQ2 — What does each side see?** Are `nameComponents` and the lookup info filled in, for both the
  owner and the participant, on each phone? **Partly answered 2026-10-30 from Jon's phone** (Settings →
  Share Travel Party, Apple's share sheet): Wendy appears by full name and photo, with the phone number her
  invitation went to, "Can edit", and "Joined October 18, 2026". Jon appears by name as Owner. There's no
  email for Wendy, because the invitation used her phone number. Still open: what Wendy's phone shows for
  Jon. The participant side can't safely open that sheet today, because the Share button re-saves the
  share, which only the owner can do.
- **OQ3 — Does Development differ from Production?** Do record names differ between environments? It only
  matters if Galavant Dev and TestFlight ever need to agree, and their data is separate (ADR-0050), so
  this is a note, not a blocker.
- **OQ4 — Acting for someone else.** Is there a real case for using a device as another planner (entering
  Wendy's votes on Jon's iPad)? Decision 3 allows it, with a confirmation. If not, it could become a
  plain refusal.

## Slices

- **Slice 0 — read-only readout (no schema).** Settings → Planners gains an **iCloud identity** section:
  this device's record name, and each share participant's record name, name, lookup info, role and acceptance
  status. It ships in a TestFlight build, so it runs on Production on both phones. Jon and Wendy read it
  on each phone and record the answers to OQ1–OQ3 here.
- **Slice 1 — claim and bind.** The column, its migration, Decisions 2, 3 and 6, and the Production schema
  deploy before the next TestFlight build. Escalated to Jon (schema, sync).
- **Slice 2 — names and dedup.** Decisions 4 and 5.

## Consequences

- New devices and reinstalls stop asking "Who are you?" once their planner is claimed.
- A wrong pick needs a deliberate confirmation instead of being silent.
- The picker stays as the fallback for an unclaimed party and for devices with no account.
- No server, no auth, no new permission prompt (ADR-0001).
