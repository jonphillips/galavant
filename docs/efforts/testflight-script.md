# Effort — `testflight`: one command from `main` to a processed TestFlight build

**Status:** Queued (2026-10-08; post-upload steps revised 2026-10-10) · **Summary:** a jon-platform
script, `testflight`, run from an app repo. It checks `main`, blocks on an undeployed CloudKit
schema, optionally bumps the marketing version through a PR it merges, archives Release with a build
number derived from git, verifies the exported app's identity and entitlements, and uploads with
Xcode. Then it uses a pinned `asc` (App Store Connect CLI) to wait for processing, tags only a
processed build, and writes "What to Test" into TestFlight. `testflight --feedback` pulls tester
feedback and crashes. Galavant is the first app to use it, Yes Chef the second. Two PRs on branch
`effort/testflight-script`: jon-platform first, then Galavant.

Jon asked for it on 2026-10-08. It automates the `PROD-CUTOVER.md` "After the cutover" rules (schema
deploy before TestFlight; Phase 4a's build checks) and ends the hand-bumped build numbers. The 0.2.0
bump edited only `project.pbxproj` and would have been reverted by the next `xcodegen generate`
(#169).

## Decisions already made (Jon)

2026-10-08:

- **Build number comes from git, never committed:** `git rev-list --count HEAD` on `main`, passed as
  `CURRENT_PROJECT_VERSION=<n>` to `xcodebuild archive`. It's monotonic because `main` is
  squash-merged and linear. `project.yml` keeps a floor value, commented as overridden at archive.
- **Archive *and* upload.** No Organizer.
- **Schema gate on**, via `cktool`.

2026-10-10 (revises the 10-08 "no API key" point):

- **Xcode does the upload; `asc` only works after it.** The upload stays `xcodebuild -exportArchive`
  with `destination` = `upload`, using the account Xcode is signed into. No `altool`, and no
  `asc builds upload` or `asc publish`. [`asc`](https://github.com/rorkai/App-Store-Connect-CLI)
  (MIT, unofficial) handles the steps after upload: wait for processing, What to Test, feedback, and
  crashes. If `asc` breaks, the build is still uploaded, and the fallback is pasting the notes by hand.
- **Only `asc` commands that use the public API.** These are `builds wait`, `builds test-notes`,
  `builds next-build-number`, `testflight feedback`, `testflight crashes` and `auth status`. All go to
  `api.appstoreconnect.apple.com`. **Never** `asc web …`, `asc validate --deep` or anything else that
  needs an Apple ID web session (private `iris` endpoints). Never `asc install-skills`.
- **One App Store Connect API key (`.p8`) is accepted.** It's a Team key with the App Manager role,
  stored in the macOS keychain via `asc auth login`, and shared by every app on the team. The
  downloaded `.p8` is deleted after login.
- **`asc` is pinned.** `ASC_VERSION` in `testflight.conf` must equal `asc --version`. Upgrading means a
  deliberate edit to that value.
- **Telemetry off.** The script exports `ASC_TELEMETRY_DISABLED=1` before any `asc` call.
- **A `testflight/*` tag means a processed build.** The tag is created only after the build reaches
  `VALID`, so a build that uploaded but failed processing never gets one.

## 1. The script (jon-platform PR)

`jon-platform/scripts/testflight`, in bash with `set -euo pipefail`, written in the style of
`scripts/plan-pr`. It reads a per-app config from the repo root, `testflight.conf` (shell `KEY=value`):

```
SCHEME=Galavant
PROJECT=Galavant.xcodeproj
XCODEGEN=1                                  # regenerate after a marketing bump
TEAM_ID=7MQEE539G9
APP_BUNDLE_ID=com.jonphillips.galavant      # also the asc --app selector
EXTENSION_BUNDLE_IDS="com.jonphillips.galavant.share"
APP_GROUP=group.com.jonphillips.galavant
CLOUDKIT_CONTAINER=iCloud.com.jonphillips.galavant
SCHEMA_GATE=1
ASC_VERSION=5.14.0                          # must equal `asc --version`
TEST_NOTES_LOCALE=en-US
DONE_LOG=docs/DONE-LOG.md
DEVICE_PASSES=docs/device-passes.md
```

**Usage:** `testflight [--bump patch|minor|major] [--dry-run] [--no-upload]`, `testflight --resume`,
`testflight --feedback`

It runs these steps in order and stops at the first failure, with a message saying what to do:

1. **Preflight.**
   - The tree is clean.
   - The current branch is `main`, and it equals `origin/main` after a fetch.
   - CI on `HEAD` is green (`gh run list --branch main --commit <sha>` or `gh api` check-runs); pending
     counts as not green.
   - `testflight.conf` parses, and Xcode and `xcodegen` (if `XCODEGEN=1`) are present.
   - **One-time setup.** Check every item, then report **all** the missing ones together under
     *"One-time setup missing:"*, each with its fix. Don't stop at the first.
     - `asc` is installed and `asc --version` equals `ASC_VERSION`. Fix: `brew install asc && brew pin
       asc`, or edit `ASC_VERSION` deliberately.
     - `asc auth status --validate` passes. Fix: the API key steps in the device-passes item below.
     - A `cktool` management token exists, when `SCHEMA_GATE=1`. Fix: `xcrun cktool save-token
       --type management`.
   - **Build-number guard.** Run `asc builds next-build-number --app "$APP_BUNDLE_ID" --platform IOS
     --processing-state all`. If `<n>` is lower than its answer, stop before archiving, because Apple
     would reject the upload. Say that an earlier hand-bumped or uploaded build is ahead of git's count.
     This check runs again after a `--bump`, against the new `<n>`.
2. **Schema gate** (when `SCHEMA_GATE=1`).
   - Run `xcrun cktool export-schema --team-id … --container-id … --environment development` and the
     same for `production`, into a temp dir, then normalize and `diff`.
   - **Any difference stops the run.** Print the diff and *"Deploy Schema Changes in the CloudKit
     Console (Development → Production), then re-run."*
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
6. **Upload** (skipped with `--no-upload`, which also skips 7–9). Run `-exportArchive` again with
   `destination` = `upload` and the same options, using the account Xcode is signed into. Once it
   succeeds, write `build/testflight/last-upload` (`VERSION=<ver>`, `BUILD=<n>`, `SHA=<HEAD sha>`) so
   `--resume` can pick up from here.
7. **Wait for processing.**

   ```
   asc builds wait --app "$APP_BUNDLE_ID" --version <ver> --build-number <n> --platform IOS \
     --timeout 45m --poll-interval 30s --fail-on-invalid --report-pending
   ```

   - `VALID` → continue.
   - `INVALID` or `FAILED` → stop with no tag. Print the state and *"Check App Store Connect → TestFlight
     for Apple's reason; fix, merge, and run `testflight` again (the new commit gives a new build
     number)."*
   - Exit 7 (still pending at the timeout) → stop with no tag. Print *"Still processing. Run `testflight
     --resume` later."*
   - Any other `asc` failure → stop, say the build *is* uploaded, and point to `--resume`.
8. **Tag.** Create the annotated tag `testflight/<ver>-<n>` on the recorded `SHA`, not `HEAD`, and
   push it. Tags aren't covered by the `main` ruleset.
9. **What to Test.** Find the previous `testflight/*` tag before this one (none means everything),
   then collect, over `prev..SHA`:
   - the squash-merge subjects (`git log --format=%s`), which are PR titles, minus the `Plan:` ones;
   - the `## ` headings added to `DONE_LOG`;
   - the bullet lines added to `DEVICE_PASSES`, as **"Check on this build"**.

   Write the full notes to `build/testflight/<ver>-<n>-notes.md`. Then build the text to send:
   - remove characters App Store Connect rejects in What to Test, using the ranges `asc` refuses:
     supplementary-plane characters (most emoji), variation selectors U+FE00–FE0F, and U+2600–27BF;
   - cap it at 4,000 characters, cutting at a line boundary and ending with `…(truncated)`.

   Send it:

   ```
   asc builds test-notes create --app "$APP_BUNDLE_ID" --version <ver> --build-number <n> \
     --platform IOS --locale "$TEST_NOTES_LOCALE" --whats-new "$notes"
   ```

   If the notes for that locale already exist (a `--resume` after a partial run), use `test-notes
   update` with the same flags.

   If `asc` fails here, the build is still valid and tagged. So don't fail the run: `pbcopy` the notes
   and print *"Couldn't set What to Test (<asc error>). It's on your clipboard; paste it in App Store
   Connect."*

   On success, print *"<ver> (<n>) processed and tagged; What to Test is set. Internal testers get it
   automatically."*

**`--resume`** reads `build/testflight/last-upload` and runs steps 7–9 for that build. It refuses if
the file is missing, or if `testflight/<ver>-<n>` already exists and the notes are already set. It
needs no clean tree and no `main` check, because it never builds. This is the recovery path:
re-running a full `testflight` on the same commit would produce the same build number, which Apple
rejects.

**`--feedback`** writes `build/testflight/feedback-<YYYY-MM-DD>.md` from
`asc testflight feedback list --app "$APP_BUNDLE_ID" --sort -createdDate --include-screenshots
--paginate --output markdown` and `asc testflight crashes list --app "$APP_BUNDLE_ID" --sort
-createdDate --paginate --output markdown`, and prints the path. It reads only and writes nothing to
App Store Connect. Turning feedback into issues or briefs is the architect's job, not the script's.

**`--dry-run`** runs steps 1 and 2, then prints the computed version, build number and the planned
commands for 3–9, including the `asc` lines. It writes the notes file from step 9 (and the
sanitized, capped text it would send) without sending, copying or tagging. It changes nothing.

### Documentation (jon-platform PR)

The script is release tooling that holds a credential and has recovery paths, so it ships with three
layers of documentation. Each fact lives in exactly one of them; the others link to it.

1. **Header comment in the script, written for agents.** Follow `plan-pr`'s header:
   - what the script does, as the numbered steps above, one line each;
   - every mode and flag with a one-line example: default, `--bump`, `--dry-run`, `--no-upload`,
     `--resume`, `--feedback`, `--help`;
   - the exit codes. 0 means done, including the case where the notes ended up on the clipboard. Each
     preflight, gate, verify or processing stop has its own documented code. Any nonzero exit after
     step 6 means *"uploaded; use `--resume`"*;
   - **What it never does:**
     - skip the schema gate;
     - upload with `asc`;
     - call an `asc web` command or any other private endpoint;
     - write to App Store Connect except What to Test;
     - push to `main` except through the `--bump` PR;
     - tag a build that hasn't processed;
   - a pointer to the runbook (layer 3) for setup and recovery.
2. **`testflight --help` / `-h`** prints that header's usage block. Extract it from the comment (for
   example with `sed` between two marker lines) so the text exists only once. No jon-platform script
   has `--help` yet, so this sets the pattern. An unknown flag prints the same
   block to stderr and exits 2. Add a `testflight` line to the `scripts/` list in jon-platform
   `README.md`, next to `plan-pr`, as one line in the same style.
3. **A runbook for Jon, at `jon-platform/docs/ios/testflight.md`.** Index it in `README.md`'s `docs/ios/`
   list. Sections:
   - **One-time setup.** The single home for these steps; Galavant's device-passes item links here and
     doesn't repeat them:
     - the `cktool` management token;
     - `brew install asc && brew pin asc`;
     - creating the App Store Connect Team key: where it lives in App Store Connect, the App Manager
       role, `asc auth login --name jon-team …`, `asc auth status --validate`, then deleting the `.p8`;
     - the `~/code/bin` symlink.
   - **Releasing.** The normal run, with and without `--bump`. What a good run's output looks like. How
     long each phase takes.
   - **When it stops.** A table: the message (or exit code) → what it means → what to do. Rows:
     - one-time setup missing;
     - CI not green;
     - the build-number guard;
     - a schema diff;
     - an export verify failure;
     - processing `INVALID`/`FAILED`;
     - still processing at 45 minutes (`--resume`);
     - What to Test fell back to the clipboard.
   - **Reading feedback.** What `--feedback` writes and what to do with it.
   - **`testflight.conf` reference.** Every key: what it's for, whether it's required, and an example.
     A new app needs only this section.
   - **Maintenance.**
     - Upgrading `asc`: read its release notes for the commands the script uses, `brew unpin`,
       upgrade, re-pin, edit `ASC_VERSION`, then a `--dry-run`.
     - Rotating or revoking the API key. It's a team key, so it affects every app.
     - Why it's built this way: Xcode uploads, `asc` uses only the public API. Link this brief's
       2026-10-10 decisions rather than restating them.

**Also in the jon-platform PR:**
- `shellcheck` clean.
- A `SEAM-LEDGER.md` note that this is shared release tooling with Galavant as the first consumer and
  Yes Chef next, so add a `testflight.conf` there when it starts shipping TestFlight builds. The note
  should also say that `asc` is a pinned external dependency limited to the public API, and that the
  App Store Connect API key is one team key shared by both apps.
- Install note: `ln -s ~/code/jon-platform/scripts/testflight ~/code/bin/testflight` (next to
  `sync-main`; `~/code/bin` must be on `PATH`).

## 2. Galavant adopts it (Galavant PR)

- `testflight.conf` as above, at the repo root. Its first line is a comment linking the runbook's
  `testflight.conf` reference.
- `build/testflight/` added to `.gitignore`.
- `project.yml`: a comment beside `CURRENT_PROJECT_VERSION` saying it's a floor that `testflight`
  overrides from git at archive time. Leave the value as it is.
- `AGENTS.md` § Production: *"Release with `testflight` from a clean `main`; it gates on schema parity,
  verifies the export, and tags only a processed build. Never hand-bump `CURRENT_PROJECT_VERSION`.
  Setup and recovery: jon-platform `docs/ios/testflight.md`."*
- `PROD-CUTOVER.md` § After the cutover: the schema-deploy rule notes that `testflight` now enforces it.

## Verification

The executor can't upload, can't reach the CloudKit management API, and has no App Store Connect API
key, so it doesn't try. **It never runs an `asc` command that writes.**

- `shellcheck` is clean on the script.
- `testflight --help` prints the header's usage block, and `testflight --bogus` prints it to stderr and
  exits 2. Every flag the script parses appears in `--help`. Every stop message the script can print
  has a row in the runbook's "When it stops" table. Check both by grepping, not by eye, and list any
  gaps in the PR.
- Run `testflight --dry-run` in Galavant. The expected stop is preflight's *"One-time setup missing:"*
  list (`asc`, its auth, the `cktool` token, whichever are absent), with each documented fix. Paste the
  output into the PR.
- Unit-test the pure parts the way jon-platform tests its other scripts:
  - semver bump;
  - tag discovery and notes assembly from a fixture repo (one case with no previous tag);
  - the What to Test sanitizer: emoji, a ZWJ sequence and U+2713 are removed; `→`, `•` and `™` are
    kept;
  - the 4,000-character cap, which cuts at a line boundary;
  - parsing `last-upload`;
  - the build-number guard comparison;
  - the entitlement/plist checker against fixture `.plist` files: one good; one with
    `aps-environment` = `development`; one with a `.dev` bundle ID; one with mismatched extension
    versions.
- Stub `asc` and `xcodebuild` with fixture scripts on `PATH` to test steps 7–9 branching:
  - `VALID` → tag, then notes;
  - `INVALID` → no tag, stop;
  - exit 7 → no tag, `--resume` message;
  - `test-notes` failure → valid, tagged, clipboard fallback, exit 0.

## Done when

- jon-platform PR merged first. Galavant PR on the same branch name, `effort/testflight-script`.
- Galavant: `scripts/check-drift.sh` green (no Swift changes expected).
- **Escalate:** release tooling, `--admin` merges, and a new external dependency holding a credential.
  The architect reviews both, then hands them to Jon.
- The completing Galavant PR:
  - adds a DONE-LOG entry;
  - marks this brief Done in `docs/efforts/README.md`;
  - adds to `docs/device-passes.md`, at the top (a held gate, not a verification gate):
    - **One-time:** follow jon-platform `docs/ios/testflight.md` § One-time setup (the `cktool`
      token, `asc` installed and pinned, the API key, the symlink). `testflight --dry-run` from clean
      `main` must report nothing missing.
    - **First real run:** `testflight` from clean `main`. Confirm:
      - the schema gate and the build-number guard pass;
      - the verify table is all pass;
      - the run waits until processing finishes, then tags;
      - What to Test shows in TestFlight on the phone;
      - `testflight --feedback` writes a file.
  - sets `docs/NEXT_UP.md` to `# Next Up` / `Nothing dispatched.`
