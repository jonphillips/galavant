# Next Up — ADR-0048 Slice 3: seed matching (saved ideas, then the map)

**Slices:** effort `adr-0048-slice-3` (one PR, branch `effort/adr-0048-slice-3`)
**Briefs:** `docs/efforts/adr-0048-slice-3-seed-matching.md`
**Done when:** per the brief's "Done when"; verification per `docs/verification.md`.
**Owed:** Jon's device pass in `docs/device-passes.md` (not executor work).
**Notes:** Matching runs inside the seed review before commit; the human's tap still selects.
No new ingestion path: resolution goes through `RecommendationResolution.confirm`. No schema
change. Start from a fresh `main`.
