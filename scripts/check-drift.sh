#!/usr/bin/env bash
set -euo pipefail

# The single verification entry point: the triple that docs/M5-EXECUTION.md and
# docs/M6-EXECUTION.md have always asked for (swiftlint / swift test / app
# build), plus one guarantee they did not cover — that the test target still
# compiles and links.
#
# Why that last one exists. YesChef's app test target held 26 tests that no
# command in that repo ever compiled, let alone ran, and its drift check
# reported green the whole time because it ended at `swift test`. When it was
# finally built it failed at link, and three of the tests turned out to encode
# expectations that had drifted months earlier — one of them hiding a real
# user-visible bug (yes-chef#247, #248).
#
# Galavant is one target-type away from the same blind spot: GalavantUITests is
# built by nothing here and run by nothing in CI. UI tests genuinely need a
# booted simulator so running them in this loop is not the goal — but "does it
# still compile and link" is free, and it is the half that rots silently.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

# Same gate as .githooks/pre-commit and ci.yml's lint job.
swiftlint lint --strict

swift test --package-path GalavantLibrary

# ---------------------------------------------------------------------------
# The test target still compiles and links
# ---------------------------------------------------------------------------

app_scheme="Galavant"
app_destination="platform=iOS Simulator,name=iPhone 17 Pro"
test_bundle="GalavantUITests"

if [[ -n "${GALAVANT_SKIP_TEST_BUILD:-}" ]]; then
  cat >&2 <<EOF

==============================================================================
  TEST TARGET NOT VERIFIED — GALAVANT_SKIP_TEST_BUILD is set.
  $test_bundle was neither compiled nor linked by this invocation. A green run
  above says nothing about it. Unset the variable before calling a run complete.
==============================================================================

EOF
else
  # Assert the target is still WIRED before building it. A build that compiles
  # nothing exits 0, so build status alone cannot tell "the tests pass the
  # compiler" apart from "the tests are no longer in this scheme" — and the
  # second is the state that rots unnoticed. Both inputs are checked in, so this
  # costs nothing. Zero hits is a failure, not a pass: a check that reports the
  # wrong thing when it finds nothing is worse than no check.
  scheme_file="Galavant.xcodeproj/xcshareddata/xcschemes/${app_scheme}.xcscheme"
  if [[ ! -f "$scheme_file" ]]; then
    printf 'check-drift.sh: expected file not found: %s\n' "$scheme_file" >&2
    exit 1
  fi
  if ! grep -q "BuildableName *= *\"${test_bundle}.xctest\"" "$scheme_file"; then
    cat >&2 <<EOF
check-drift.sh: $scheme_file has no $test_bundle testable reference.
The test target is not in the scheme's test action, so build-for-testing would
not build it and a green run below would mean nothing. Restore it in project.yml
and run xcodegen generate.
EOF
    exit 1
  fi

  set +e
  test_source_count="$(find "$test_bundle" -type f -name '*.swift' 2>/dev/null | wc -l | tr -d ' ')"
  set -e
  if (( test_source_count == 0 )); then
    cat >&2 <<EOF
check-drift.sh: found no Swift sources in $test_bundle/.
build-for-testing would build an empty bundle and report success. Refusing to
report success on a check that inspected nothing.
EOF
    exit 1
  fi
  echo "Test target: $test_source_count source file(s) in $test_bundle, wired into the scheme."

  # `build-for-testing`, not `test`. It compiles AND LINKS the bundle, needs a
  # simulator *destination* but never boots one, and is incremental after the
  # first run. Running UI tests is a separate, deliberate act.
  echo "Building $test_bundle for ${app_destination}..."
  set +e
  xcodebuild build-for-testing \
    -scheme "$app_scheme" \
    -destination "$app_destination" \
    -skipMacroValidation \
    CODE_SIGNING_ALLOWED=NO
  build_status=$?
  set -e
  if (( build_status != 0 )); then
    cat >&2 <<EOF
check-drift.sh: build-for-testing failed for scheme $app_scheme (exit $build_status).
Nothing else in this repo compiles $test_bundle, so a break here is usually stale
test code rather than a regression in the app.
EOF
    exit 1
  fi
fi

cat <<EOF

check-drift.sh: swiftlint, GalavantLibrary tests, and the $test_bundle build all passed.
$test_bundle was COMPILED AND LINKED, NOT RUN — running UI tests boots a simulator
and is a separate, deliberate step.

EOF
