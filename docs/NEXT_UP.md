# Next Up — `testflight`: one command from main to a verified TestFlight upload

**Slices:** effort `testflight-script`: two PRs on branch `effort/testflight-script`, jon-platform
first, then Galavant
**Briefs:** `docs/efforts/testflight-script.md`
**Done when:** per the brief's "Done when"; verification per `docs/verification.md`.
**Owed:** Jon's one-time `cktool` management token and `~/code/bin` symlink, then the first real
run. Release tooling with `--admin` merges, so the architect escalates both PRs to Jon before merge.
**Notes:** The build number comes from git and is never committed. The schema gate has no skip
flag. Verify the export *before* upload (two-phase export). Start from a fresh `main` in both repos.
