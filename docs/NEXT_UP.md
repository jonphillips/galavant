# Next Up — Galavant Dev: Debug builds get their own bundle ID, app group, name and icon

**Slices:** effort `galavant-dev-variant` (one PR, branch `effort/galavant-dev-variant`)
**Briefs:** `docs/efforts/galavant-dev-variant.md`
**Done when:** per the brief's "Done when"; verification per `docs/verification.md`.
**Owed:** Jon's one-time portal setup (`.dev` App IDs, app group, container assignment, WeatherKit in
both tabs) before his first device run. Identifiers and entitlements change, so the architect
escalates the PR to Jon before merge.
**Notes:** ADR-0050. Release must be unchanged: prove it with the Debug/Release identity table in the
PR. The container stays the same; the app group never falls back to production. Start from a fresh
`main`.
