# Next Up — `testflight`: one command from main to a processed TestFlight build

**Slices:** effort `testflight-script`: two PRs on branch `effort/testflight-script`, jon-platform
first, then Galavant
**Briefs:** `docs/efforts/testflight-script.md` (revised 2026-10-10: read the whole brief, not a
summary of it)
**Done when:** per the brief's "Done when"; verification per `docs/verification.md`.
**Owed:** Jon's one-time setup is in the new jon-platform runbook `docs/ios/testflight.md`: the
`cktool` management token, `asc` installed and pinned, the App Store Connect Team API key, and the
`~/code/bin` symlink. Then the first real run. This is release tooling with `--admin` merges and a
new external dependency that holds a credential, so the architect escalates both PRs to Jon
before merge.
**Notes:**
- Xcode does the upload. A pinned `asc` only runs after it, and only the public-API commands the
  brief lists. Never `asc web`, `asc validate --deep`, `asc install-skills`, or an `asc` upload.
- Never run an `asc` command that writes. Test steps 7–9 with stubs on `PATH`.
- The build number comes from git and is never committed. The schema gate has no skip flag.
- Verify the export *before* upload (two-phase export). Tag only a `VALID` build.
- Documentation is part of the deliverable: the header comment, `--help`, and the runbook.
- Start from a fresh `main` in both repos.
