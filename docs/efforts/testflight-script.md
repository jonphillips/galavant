# Effort — `testflight`: one command from `main` to a verified TestFlight upload

**Status:** Queued (2026-10-08) · **Summary:** a jon-platform script, `testflight`, run from an app
repo. It checks `main`, blocks on an undeployed CloudKit schema, optionally bumps the marketing
version through a PR it merges, archives Release with a build number derived from git, verifies the
exported app's identity and entitlements, uploads to App Store Connect, tags the release, and copies
"What to Test" notes to the clipboard. Galavant is the first app to use it, Yes Chef the second. Two
PRs on branch `effort/testflight-script`: jon-platform first, then Galavant.

Jon asked for it on 2026-10-08. It automates the `PROD-CUTOVER.md` "After the cutover" rules (schema
deploy before TestFlight; Phase 4a's build checks) and ends the hand-bumped build numbers. The 0.2.0
bump edited only `project.pbxproj` and would have been reverted by the next `xcodegen generate`
(#169).

## Decisions already made (Jon, 2026-10-08)

- **Build number comes from git, never committed:** `git rev-list --count HEAD` on `main`, passed as
  `CURRENT_PROJECT_VERSION=<n>` to `xcodebuild archive`. It's monotonic because `main` is
  squash-merged and linear. `project.yml` keeps a floor value, commented as overridden at archive.
- **Archive *and* upload.** No Organizer.
- **Schema gate on**, via `cktool`.

## 1. The script (jon-platform PR)

`jon-platform/scripts/testflight`, in bash with `set -euo pipefail`, written in the style of
`scripts/plan-pr`. It reads a per-app config from the repo root, `testflight.conf` (shell `KEY=value`):

```
SCHEME=Galavant
PROJECT=Galavant.xcodeproj
XCODEGEN=1                                  # regenerate after a marketing bump
TEAM_ID=7MQEE539G9
APP_BUNDLE_ID=com.jonphillips.galavant
EXTENSION_BUNDLE_IDS="com.jonphillips.galavant.share"
APP_GROUP=group.com.jonphillips.galavant
CLOUDKIT_CONTAINER=iCloud.com.jonphillips.galavant
SCHEMA_GATE=1
DONE_LOG=docs/DONE-LOG.md
DEVICE_PASSES=docs/device-passes.md
```

**Usage:** `testflight [--bump patch|minor|major] [--dry-run] [--no-upload]`

It runs these steps in order and stops at the first failure, with a message saying what to do:

1. **Preflight.**
   - The tree is clean.
   - The current branch is `main`, and it equals `origin/main` after a fetch.
   - CI on `HEAD` is green (`gh run list --branch main --commit <sha>` or `gh api` check-runs); pending
     counts as not green.
   - `testflight.conf` parses, and Xcode and `xcodegen` (if `XCODEGEN=1`) are present.
2. **Schema gate** (when `SCHEMA_GATE=1`).
   - Run `xcrun cktool export-schema --team-id … --container-id … --environment development` and the
     same for `production`, into a temp dir, then normalize and `diff`.
   - **Any difference stops the run.** Print the diff and *"Deploy Schema Changes in the CloudKit
     Console (Development → Production), then re-run."*
   - A missing management token stops it too, with the one-time fix: `xcrun cktool save-token --type
     management`.
   - There is deliberately **no skip flag**. If Development has a leftover, the fix is to delete it in
     the console (`PROD-CUTOVER.md` Phase 1), not to bypass the gate.
3. **Marketing bump** (only with `--bump`).
   - Compute the next semver from `project.yml`'s `MARKETING_VERSION` and edit it in place, with no
     other changes. Run `xcodegen generate` if configured.
   - Branch `release/<version>`, commit `project.yml` and the regenerated project, push, open a PR, and
     merge it with `gh pr merge --squash --admin`.
   - Then `git switch main && git pull --ff-only`. Every later step runs on that merged `main`.
4. **Archive.**

   ```
   xcodebuild archive -project … -scheme … -configuration Release \
     -destination 'generic/platform=iOS' -archivePath build/testflight/<ver>-<n>.xcarchive \
     -allowProvisioningUpdates CURRENT_PROJECT_VERSION=<n>
   ```

   Pipe it through `scripts/quiet-run`, or keep the log in `build/testflight/`, so a failure shows the
   real error.
5. **Export locally, then verify.** Export with a generated `ExportOptions.plist`:
   - `method` = `app-store-connect`, `destination` = `export`, `teamID`, automatic signing;
   - **`manageAppVersionAndBuildNumber` = `false`**, so Xcode can't renumber the build;
   - `uploadSymbols` = `true`.

   Unzip the `.ipa`, and for `Payload/<App>.app` and every `PlugIns/*.appex`, check:
   - `CFBundleIdentifier` equals the config (the app, then each extension), and **never** contains
     `.dev` (ADR-0050);
   - `CFBundleShortVersionString` and `CFBundleVersion` are `<ver>` and `<n>`, the same in the app and
     every extension;
   - from `codesign -d --entitlements :- …`: `com.apple.security.application-groups` is exactly
     `[APP_GROUP]`; `com.apple.developer.icloud-container-identifiers` contains `CLOUDKIT_CONTAINER`;
     `aps-environment` is **`production`** (app only); `com.apple.developer.icloud-container-environment`
     is `Production` where present.

   Print a pass/fail table. Any failure stops the run before upload.
6. **Upload** (skipped with `--no-upload`). Run `-exportArchive` again with `destination` = `upload` and
   the same options. It uses the account Xcode is signed into. No API key and no `altool`.
7. **Tag.** Create the annotated tag `testflight/<ver>-<n>` on `HEAD` and push it. Tags aren't covered by
   the `main` ruleset.
8. **What to Test.** Find the previous `testflight/*` tag (none means everything), then collect:
   - the squash-merge subjects since that tag (`git log --format=%s prev..HEAD`), PR titles minus the
     `Plan:` ones;
   - the `## ` headings added to `DONE_LOG` since that tag;
   - the bullet lines added to `DEVICE_PASSES` since that tag, as **"Check on this build"**.

   Write `build/testflight/<ver>-<n>-notes.md` and `pbcopy` it. Print *"Uploaded <ver> (<n>).
   Processing usually takes 10–30 minutes, and internal testers get it automatically. What to Test is
   on your clipboard."*

**`--dry-run`** runs steps 1 and 2, prints the computed version, build number and planned commands for
3–7, and writes the notes from step 8 without copying or tagging. It changes nothing.

**Also in the jon-platform PR:**
- `shellcheck` clean.
- A usage section where jon-platform documents its scripts (follow `plan-pr` and `check-handoff`).
- A `SEAM-LEDGER.md` note that this is shared release tooling with Galavant as the first consumer and
  Yes Chef next, so add a `testflight.conf` there when it starts shipping TestFlight builds.
- Install note: `ln -s ~/code/jon-platform/scripts/testflight ~/code/bin/testflight` (next to
  `sync-main`; `~/code/bin` must be on `PATH`).

## 2. Galavant adopts it (Galavant PR)

- `testflight.conf` as above, at the repo root.
- `build/testflight/` added to `.gitignore`.
- `project.yml`: a comment beside `CURRENT_PROJECT_VERSION` saying it's a floor that `testflight`
  overrides from git at archive time. Leave the value as it is.
- `AGENTS.md` § Production: *"Release with `testflight` from a clean `main`; it gates on schema parity
  and verifies the export. Never hand-bump `CURRENT_PROJECT_VERSION`."*
- `PROD-CUTOVER.md` § After the cutover: the schema-deploy rule notes that `testflight` now enforces it.

## Verification

The executor can't upload or reach the CloudKit management API, so it doesn't try.

- `shellcheck` is clean on the script.
- `testflight --dry-run` runs in Galavant and gets as far as the schema gate. A missing management token
  is the expected stop, and its message is the documented one. Paste the output into the PR.
- Unit-test the pure parts the way jon-platform tests its other scripts: semver bump, tag
  discovery/notes assembly from a fixture repo, and the entitlement/plist checker against fixture
  `.plist` files (one good; one with `aps-environment` = `development`; one with a `.dev` bundle ID;
  one with mismatched extension versions).

## Done when

- jon-platform PR merged first. Galavant PR on the same branch name, `effort/testflight-script`.
- Galavant: `scripts/check-drift.sh` green (no Swift changes expected).
- **Escalate:** release tooling plus `--admin` merges. The architect reviews both, then hands them to Jon.
- The completing Galavant PR:
  - adds a DONE-LOG entry;
  - marks this brief Done in `docs/efforts/README.md`;
  - adds to `docs/device-passes.md`, at the top (a held gate, not a verification gate): *one-time:
    `xcrun cktool save-token --type management`, and symlink `testflight` into `~/code/bin`. First real
    run: `testflight` from clean `main`; confirm the schema gate passes, the verify table is all pass,
    the build appears in TestFlight, and the notes are on the clipboard;*
  - sets `docs/NEXT_UP.md` to `# Next Up` / `Nothing dispatched.`
