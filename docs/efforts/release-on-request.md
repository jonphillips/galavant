# Effort — One-tap release from the iPad

Status: Ready
Summary: `testflight-renew request <app>` drops a request file over SSH, and a second LaunchAgent on the mini releases the app from its logged-in session, where the Keychain is unlocked, then reports by iMessage (jon-platform ADR-0012).

## Why

Jon wants a home-screen button that ships Galavant's `main` to TestFlight. Running `testflight` from a
Shortcuts SSH action fails, because an SSH session sees the login Keychain as locked and `asc` can't
read its credentials (2026-11-28). The design is jon-platform
[ADR-0012](https://github.com/jonphillips/jon-platform/blob/main/docs/adr/0012-release-on-request.md),
and this brief builds it. Galavant hosts the dispatch because it's the first app with a button; the
script serves every app with a `testflight.conf`.

## Dispatch 1 — Build

**S1 — jon-platform `scripts/testflight-renew`.** This is a jon-platform PR, and it comes first.
Extend the existing script; don't add a new one. Keep its conventions (labels, logs, `STATE_DIR`,
the lock, `notify`).
- **`install`** also writes and bootstraps a second user LaunchAgent,
  `com.jonphillips.testflight-release`, with the same handle, repos, and `PATH`. It runs
  `testflight-renew serve-requests --to HANDLE REPO...` and names `$STATE_DIR/requests` in
  `QueueDirectories` (create the folder at install). **`uninstall`** removes both agents.
  **`status`** shows both agents and any pending request.
- **`request APP`** (what the shortcut runs; no `launchctl`).
  - Read the repo list from the installed release agent's plist. `APP` must equal the base name of one
    of them. Anything else, or no agent installed: print why, exit 2.
  - `APP` already pending (file present) or releasing (a running marker the server writes): print
    which, exit 3.
  - Otherwise create `$STATE_DIR/requests/APP` (empty), then wait up to 10 seconds for it to be
    claimed. Claimed: print `Started APP; you'll get an iMessage when it's done.`, exit 0. Not claimed:
    print `Queued APP, but the release agent hasn't picked it up; run testflight-renew status.`,
    exit 0.
- **`serve-requests --to HANDLE REPO...`** (what the release agent runs).
  - For each file in the request folder, oldest first: delete it (the claim). A name that isn't a
    configured repo's base name is logged and dropped, with no message.
  - Write the app's running marker, take the renewal's lock **waiting** for it (poll; don't exit),
    then release exactly as `run --force` does for that repo: clean-and-on-`main` check, `git pull
    --ff-only`, `testflight`, and the same success and failure messages. Remove the marker when done,
    including on failure.
  - Exit once the folder is empty, so launchd doesn't restart it in a loop.
- **Tests, in `scripts/tests/testflight-renew.sh`,** with the existing stubs. Cover:
  - `request galavant` with the agent installed creates the file; a stubbed claim prints `Started`;
    no claim within the wait prints `Queued`;
  - `request` refuses an unknown app, a name with `/` or `..`, a pending app, and a releasing app,
    with the documented exit codes, and creates no file;
  - `serve-requests` releases one request (stubbed `testflight` runs once, one success message) and
    leaves the folder empty;
  - it drops an unknown request with no `testflight` and no message;
  - with the lock held, it waits, then releases once the lock is freed;
  - a dirty tree sends the failure message and still removes the marker;
  - `install` writes a second plist that passes `plutil -lint`, with `QueueDirectories`, the args,
    and `PATH`; `uninstall` removes both.
- **Docs.**
  - `scripts/README.md`: the script's line mentions `request`.
  - `docs/ios/testflight.md` § Renewal: a "One-tap release" paragraph with the Shortcuts action
    (Run Script Over SSH, SSH key, script
    `~/code/jon-platform/scripts/testflight-renew request <app>`).
  - Mark ADR-0012 accepted and implemented in its status line and in `docs/adr/README.md`.

**S2 — The app's records.** The companion PR here has no code. Closeout (ADR-0005 D16) adds the
`DONE-LOG.md` entry naming both branches and the jon-platform PR, appends the gate below, archives
this brief, and advances `NEXT_UP.md`.

**Done when:**
- S1's PR is merged. It lists `scripts/tests/testflight-renew.sh` passing under `/bin/bash` and
  `bash`, and `bash -n scripts/testflight-renew`.
- Installing on the mini isn't the executor's to do. The PR says so.
- S2 is merged, with closeout (ADR-0005 D16). The gate, on the mini, after `testflight-renew install`
  (jon-platform `always-on-mac.md` Phase 2 step 8): from the iPad, a Shortcuts **Run Script Over SSH**
  action with the iPad's SSH key runs `~/code/jon-platform/scripts/testflight-renew request galavant`.
  The shortcut shows `Started galavant`, and an iMessage reports a released build. That proves the
  request path, the Keychain from launchd, and the message.

**Notes.** ADR-0012 merged in jon-platform #195. Shared code.
Don't change `scripts/testflight` or the daily renewal's behavior. The renewal's own Fit Happens gate
may run at the same install; the two gates are independent.
