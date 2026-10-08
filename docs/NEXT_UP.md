# Next Up — Taste Profile identity: explain a missing identity; Planners "This is me"

**Slices:** effort `taste-profile-identity` (one PR, branch `effort/taste-profile-identity`)
**Briefs:** `docs/efforts/taste-profile-identity.md`
**Done when:** per the brief's "Done when"; verification per `docs/verification.md`.
**Owed:** Jon's device gates in `docs/device-passes.md` (not executor work).
**Notes:** Identity is device-local (ADR-0008), so there's no schema, sync or synced-row write. The
editor reads `currentPlannerID` live instead of at init. Start from a fresh `main`.
