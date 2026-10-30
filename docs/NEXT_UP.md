# Next Up — ADR-0051 Slice 0: the iCloud identity readout

**Slices:** effort `adr-0051-s0-identity-readout` (one PR, branch `effort/adr-0051-s0-identity-readout`)
**Briefs:** `docs/efforts/adr-0051-s0-identity-readout.md`
**Done when:** per the brief's "Done when"; verification per `docs/verification.md`.
**Owed:** Production cutover Phase 6's M5 gate (Wendy) and the verification gates; see [`device-passes.md`](device-passes.md). This effort adds a synced column, so the architect escalates the PR to Jon, and the Production schema deploy comes before the next TestFlight build.
**Notes:** ADR-0051 (accepted). Read only: no schema, no CloudKit writes, never `share(record:)`.
The readout ships in Release builds. Start from a fresh `main`.
