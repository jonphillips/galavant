# Verification

The standing pattern for every dispatch (jon-platform ADR-0005). Compile and test, then hand off:
Jon reviews on his own device, so **no simulator walkthroughs, installs, screenshots, or taps**.
Name any device-only risk in the PR as unverified and stop.

## The gate

`scripts/check-drift.sh` is the single entry point: SwiftLint, `swift test --package-path
GalavantLibrary`, a `build-for-testing` pass that compiles and links `GalavantUITests`, and the
shared `check-handoff` document-shape hygiene (warn-only). Each noisy stage runs through
jon-platform's `quiet-run`, so only errors and verdicts print and the full logs stay on disk. It never
boots a simulator.

The `build-for-testing` stage exists because `GalavantUITests` is compiled by nothing else here and
run by nothing in CI, which is exactly how a test target rots unnoticed. `GALAVANT_SKIP_TEST_BUILD=1`
skips it and says so loudly.

Start with the narrowest check (`swift test --package-path GalavantLibrary --filter …`), and run the
full gate once before marking a PR ready.

## App-target tests (run headless when a dispatch touches app models)

```bash
~/code/jon-platform/scripts/quiet-run xcodebuild test-without-building -scheme Galavant \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:GalavantTests CODE_SIGNING_ALLOWED=NO
```

Check the "Test run with N tests" line, not just the exit code: see the XcodeGen trap below.

## XcodeGen: the project is generated, but the pbxproj is tracked

- Edit `project.yml`, run `xcodegen generate`, and commit **both** `project.yml` and
  `Galavant.xcodeproj/project.pbxproj`. Never hand-edit the pbxproj. Committing `project.yml` alone
  leaves a stale pbxproj that silently reverts the change.
- Every SPM product a target imports must be declared in that target's `dependencies:`, or the next
  regenerate drops the link and the build fails with `Undefined symbols`.
- A new file in `GalavantTests/` needs a regenerate. Otherwise the run reports *passed* having executed
  none of the new tests.
- A pbxproj merge conflict is never hand-merged: take either side, regenerate from the merged
  `project.yml`, then build.
