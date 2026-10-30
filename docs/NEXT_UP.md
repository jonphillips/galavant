# Next Up — Visited roll-up: a finished trip marks its places visited

**Slices:** effort `visited-rollup` (one PR, branch `effort/visited-rollup`)
**Briefs:** `docs/efforts/visited-rollup.md`
**Done when:** per the brief's "Done when"; verification per `docs/verification.md`.
**Owed:** Production cutover Phase 6's M5 gate (Wendy) and the verification gates; see [`device-passes.md`](device-passes.md). This effort adds a synced column, so the architect escalates the PR to Jon, and the Production schema deploy comes before the next TestFlight build.
**Notes:** ADR-0004 and ADR-0039 §1. The roll-up flips `Idea.visited` only; stop status and the live check-off overlay are untouched. Start from a fresh `main`.
