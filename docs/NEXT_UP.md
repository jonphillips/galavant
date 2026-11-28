# Next Up — One-tap release from the iPad · Dispatch 1

**Slices:** release-on-request Dispatch 1 (S1 in jon-platform, then S2 here)
**Briefs:** docs/efforts/release-on-request.md §Dispatch 1; jon-platform docs/adr/0012-release-on-request.md
**Done when:** per the brief. S1: a jon-platform PR adds `request` and `serve-requests` and a second LaunchAgent to `scripts/testflight-renew`, with the stub tests in `scripts/tests/testflight-renew.sh` and the doc lines. It lists that test passing under `/bin/bash` and `bash`, and `bash -n scripts/testflight-renew`. S2, here: a records-only PR. Closeout (ADR-0005 D16) appends the gate, archives the brief, and leaves `NEXT_UP.md` empty.
**Owed:** see [device-passes.md](device-passes.md)
**Notes:** S1 is shared code. The architect merges it after rerunning its verification. Needs jon-platform #195 merged first. The gate is Jon's, from the iPad, after the mini's `testflight-renew install`.
