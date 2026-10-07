# Next Up — ADR-0048 Slice 3: seed matching

**Slices:** effort `adr-0048-slice-3` (one PR, branch `effort/adr-0048-slice-3`)
**Briefs:** `docs/efforts/adr-0048-slice-3-seed-matching.md`
**Done when:** per the brief's "Done when"; verification per `docs/verification.md`.
**Owed:** Jon's device passes in `docs/device-passes.md` (not executor work).
**Notes:** Re-dispatched now that ADR-0049 S1 has shipped; the brief is unchanged since it was parked.
Inside Slice 2's seed review: match rows to saved ideas, then the map; one tap confirms the obvious
matches; confirmed rows resolve inside the existing one-transaction import. `obviousChoice` only
pre-selects; the human tap is the selection. At most 4 map searches at once. No schema change. New
presentations stay in `TripDetailContent` (KNOWN-ISSUES standing rule). Start from a fresh
`main`.
