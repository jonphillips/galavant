# Next Up — Travel profile: Settings entry + ChatGPT briefs + chat

**Slices:** effort `travel-profile` (one PR, branch `effort/travel-profile`)
**Briefs:** `docs/efforts/travel-profile-wiring.md`
**Done when:** per the brief's "Done when"; verification per `docs/verification.md`.
**Owed:** FIRST WRITE to the synced `travelProfiles` table. Before the TestFlight build: Jon pushes a
shared profile and a planner overlay from a development build, confirms every field in the
Development schema, and deploys the schema to Production (`docs/device-passes.md`). The architect
escalates the PR to Jon before merge.
**Notes:** No migration and no contract-version bump. The briefs and chat read the profile
explicitly; no `ModelClient`-boundary injection (ADR-0015 §3 amendment). Start from a fresh `main`.
