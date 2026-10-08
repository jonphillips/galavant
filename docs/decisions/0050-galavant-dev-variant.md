# ADR-0050: Galavant Dev — Debug builds get their own app identity, and share the CloudKit container

*Status: **proposed** — 2026-10-08, from a design conversation with Jon after the Production cutover.
Ratified when Jon merges the plan PR that adds it. Builds on
[ADR-0049](0049-backup-restore-and-production-cutover.md) (Production cutover) and
[ADR-0006](0006-naming.md) (naming). Effort: [`galavant-dev-variant`](../efforts/galavant-dev-variant.md).*

## Context

Since 2026-10-08, Jon's iPhone and iPad run the **TestFlight** build against CloudKit **Production**
(`PROD-CUTOVER.md`). An Xcode Run produces a development-signed build with the **same** bundle ID and
app group, and that build talks to CloudKit **Development**. Installing one over TestFlight puts the
real local library behind the other environment. The sync metadatabase is keyed by container, not
environment, so its bookkeeping goes wrong in ways the cutover runbook spent six phases avoiding. The
only safe development targets today are the simulator or a spare device. The simulator has no Apple
Intelligence, and a spare device has to be able to run iOS 27.

The schema loop needs a development build. Every slice that adds or first writes a synced column has to
push it from a development build to the Development schema before the Production deploy (`AGENTS.md` §
Production). The first case, `travelProfiles` (#167), ran on the simulator.

## Decision

**D1 — The Debug configuration builds "Galavant Dev", a second app that can sit next to the TestFlight
build on the same device.** Release builds stay exactly as they are.

| | Release (TestFlight) | Debug (Galavant Dev) |
| --- | --- | --- |
| App bundle ID | `com.jonphillips.galavant` | `com.jonphillips.galavant.dev` |
| Share extension | `com.jonphillips.galavant.share` | `com.jonphillips.galavant.dev.share` |
| App group | `group.com.jonphillips.galavant` | `group.com.jonphillips.galavant.dev` |
| iCloud container | `iCloud.com.jonphillips.galavant` | **same** |
| CloudKit environment | Production | Development (development signing selects it) |
| Display name (app and share sheet) | Galavant | Galavant Dev |
| Icon | `AppIcon` | `AppIcon-Dev` (the same art with an orange DEV banner) |

**D2 — The app group is what isolates the data, so it must differ.** The SQLite store, its SQLiteData
metadatabase, the share extension's handoff and the app-group defaults (`RecentTrip`) all live in the
app group. A dev app that shared it would be the same collision with a different name. The app group
reaches runtime code through an `Info.plist` key set from a build setting, read by
`GalavantStorage.appGroupID`. **A missing key fails loudly, never silently falling back to the
production group.**

**D3 — The container must stay the same.** The schema loop depends on it: Galavant Dev writes the
*Development* environment of the real container, and that schema is what gets deployed to Production.
A separate `….dev` container would have a schema that can never be deployed. The container identifier
stays a constant.

**D4 — Production identity is frozen.** No Release identifier changes: the bundle IDs, the app group
and the container are the ones the cutover carried the library across with (`PROD-CUTOVER.md`
precondition). Every difference lives in the Debug configuration.

**D5 — `.dev` is an environment, not a version.** [ADR-0006](0006-naming.md) bans *version* suffixes
("V3") anywhere in the namespace, and that still holds. A Debug-only environment suffix on bundle IDs
and the app group is outside that rule. It never appears in Release, in module or target names, or in
the container.

## Consequences

- **Device roles.** The main iPhone and iPad can run both apps. Galavant (TestFlight) is real use and
  every device pass. Galavant Dev is the schema loop and pre-release checks, including Apple
  Intelligence. The simulator remains an option; a spare device isn't needed.
- **Galavant Dev downloads the Development zone,** which still holds the pre-cutover library and is the
  rollback copy until the M5 gate. After the gate passes, **Reset Development Environment** can empty it
  (OQ1).
- **Dev data and shares stay in Development.** Wendy never sees anything from Galavant Dev, and a share
  made in Development is between Development builds only.
- **Device-local state starts fresh** in Galavant Dev: the planner identity, sync enablement, AI API keys
  in the keychain, and appearance settings. That's expected, and an advantage.
- **Jon does one-time portal work:** register the two `.dev` App IDs and the `.dev` app group, and
  assign the existing container to them (Xcode automatic signing does most of this). Also enable
  **WeatherKit** on `com.jonphillips.galavant.dev` in both the Capabilities and App Services tabs (the
  known WeatherKit trap).
- **Cross-app:** Yes Chef will need the same split before its own cutover. Recorded in the jon-platform
  `SEAM-LEDGER.md`; Yes Chef keeps its own decision.

## Open questions

- **OQ1 — When to reset the Development environment.** It's the rollback copy until the M5 gate passes on
  Production. After that, a reset makes Galavant Dev light. The reset also resets the Development schema
  to Production's, which is harmless: deploys only add.
- **OQ2 — Refuse cross-environment restores outright?** Debug backups are named `Galavant-Dev-Backup-…`
  and say "Galavant Dev", so a mix-up is visible, but the production importer still *accepts* a
  Development library. A hard refusal needs an environment marker written into the backup and checked on
  restore. That's a CloudSyncKit (jon-platform) change, shared with Yes Chef. Decide when Yes Chef adopts
  its own dev variant.
