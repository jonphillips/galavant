# Next Up — Sync status reports what didn't sync

**Slices:** effort `sync-failure-surfacing` (one PR, branch `effort/sync-failure-surfacing`)
**Briefs:** `docs/efforts/sync-failure-surfacing.md`
**Done when:** per the brief's "Done when"; verification per `docs/verification.md`.
**Owed:** TestFlight first-run completion, Production cutover Phase 6's M5 gate (Wendy) and the
verification gates. See [`device-passes.md`](device-passes.md). This effort touches sync, so the
architect escalates the PR to Jon before merge.
**Notes:** Follow-up to #176. The `CloudSyncKit` side is shipped (jon-platform #72, #82–#84); this is the
Galavant wiring only. Read Yes Chef's `docs/efforts/sync-failure-surfacing.md` first. Keep the row naming
pure, in `GalavantSchema`. Start from a fresh `main`.
