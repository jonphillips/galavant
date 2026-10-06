# Next Up — ADR-0049 S1: backup & restore

**Slices:** effort `adr-0049-s1` (one PR, branch `effort/adr-0049-s1-backup-restore`)
**Briefs:** `docs/efforts/adr-0049-s1-backup-restore.md`
**Done when:** per the brief's "Done when"; verification per `docs/verification.md`.
**Owed:** Jon's device pass in `docs/device-passes.md` (not executor work).
**Notes:** Adopt `CloudSyncKit`; don't re-implement or patch it here. Move the migration registrations, never
edit a body. Backup and restore are owner-only (hidden on a participant's phone). Touches sync, so the
architect escalates the PR to Jon. Start from a fresh `main`.
