# Effort — Galavant Dev: Debug builds get their own bundle ID, app group, name and icon

**Status:** Queued (2026-10-08) · **Summary:** implements [ADR-0050](../decisions/0050-galavant-dev-variant.md).
Xcode Run (Debug) builds **Galavant Dev**, with its own bundle IDs, app group, display name and icon, so
it can sit next to the TestFlight app on Jon's devices. It still uses the real iCloud container, which
puts it on CloudKit Development. Release is byte-for-byte unchanged. No schema, migration or sync-model
change.

## Before you start (Jon's part; flag it if it isn't done)

Automatic signing creates most of this on the first Debug build. Two steps it can't do:

- **WeatherKit** on App ID `com.jonphillips.galavant.dev`, in **both** the Capabilities and App Services
  tabs.
- **The iCloud container `iCloud.com.jonphillips.galavant`** assigned to both `.dev` App IDs, and the
  app group `group.com.jonphillips.galavant.dev` registered.

The executor's build is compile-only (`CODE_SIGNING_ALLOWED=NO` is fine), so it doesn't need the portal.
Jon's first device run does.

## 1. Per-configuration identity in `project.yml`

Use build settings, set per configuration on **both** the `Galavant` and `GalavantShare` targets. Names
are suggestions:

| Setting | Debug | Release |
| --- | --- | --- |
| `GALAVANT_BUNDLE_ID` | `com.jonphillips.galavant.dev` | `com.jonphillips.galavant` |
| `PRODUCT_BUNDLE_IDENTIFIER` | `$(GALAVANT_BUNDLE_ID)`, and `$(GALAVANT_BUNDLE_ID).share` for the extension | same |
| `GALAVANT_APP_GROUP` | `group.com.jonphillips.galavant.dev` | `group.com.jonphillips.galavant` |
| `GALAVANT_DISPLAY_NAME` | `Galavant Dev` | `Galavant` |
| `ASSETCATALOG_COMPILER_APPICON_NAME` (app only) | `AppIcon-Dev` | `AppIcon` |

- **Entitlements:** both targets' `com.apple.security.application-groups` become
  `[$(GALAVANT_APP_GROUP)]`. Entitlements expand build settings. The iCloud container entries stay
  literal (ADR-0050 D3). `aps-environment` stays as it is; the Release export rewrites it.
- **Info.plist:** both targets get `CFBundleDisplayName: $(GALAVANT_DISPLAY_NAME)` (the extension
  currently hard-codes `Galavant`), plus a new key, `GalavantAppGroupID: $(GALAVANT_APP_GROUP)`.
- **Icon:** add `AppIcon-Dev.appiconset` beside `AppIcon`. Use the same artwork with an orange
  **DEV** banner across the bottom, readable at home-screen size. A single 1024 image is fine, as
  `AppIcon` already does.
- **Test targets** host on whatever the app is in that configuration. Check that `GalavantTests` and
  the UI-test build still compile and run headless under Debug.
- Run `xcodegen generate` and commit the regenerated project. Never hand-edit `project.pbxproj`.

## 2. Runtime reads the app group; nothing falls back to production

- `GalavantStorage.appGroupID`
  ([Database.swift](../../GalavantLibrary/Sources/GalavantSchema/Database.swift)) reads
  `Bundle.main.object(forInfoDictionaryKey: "GalavantAppGroupID")`. That's the app's or the extension's
  own `Info.plist`, as appropriate.
- **A missing or empty key is loud.** Report it with `reportIssue` and fail the store open, with a clear
  message naming the key. **Never fall back to `group.com.jonphillips.galavant`**: a Debug build missing
  its key would silently share the TestFlight app's store, which is the exact collision ADR-0050
  prevents. Package tests that never open the app-group store aren't affected. If a test does need it,
  inject the identifier; don't default it.
- Every app-group consumer goes through `appGroupID`: the store URL, the metadatabase (it sits next to
  the store), and `RecentTrip`'s `UserDefaults(suiteName:)`. Grep for any other literal
  `group.com.jonphillips.galavant` and route it through too.
- `GalavantCloudSync`'s container identifier **stays a constant** (D3). Don't parameterize it.

## 3. Show which build you're in

The Settings footer (or the Developer section, which is already Debug-only) shows *"Galavant Dev ·
CloudKit Development"* in Debug, so a screenshot says which world it came from. Release shows nothing
new.

## Tests

1. **Package:** reading the app group from a supplied info dictionary returns the value, and a
   missing or empty key reports an issue (`withKnownIssue` / `expectIssue`) instead of returning the
   production group. Put the read behind a small pure function that takes the dictionary, so it's
   testable without `Bundle.main`.
2. **Build check:** in the PR, list the built Debug and Release `Info.plist` values for
   `CFBundleIdentifier`, `CFBundleDisplayName` and `GalavantAppGroupID`, and the app-group entitlement,
   for the app and the extension. Get them with `plutil -p` on the built products and
   `codesign -d --entitlements -` where signing applies, or from the resolved build settings
   (`xcodebuild -showBuildSettings -configuration Debug|Release`). Paste the table into the PR
   description. This is the evidence that **Release didn't change**.

## Done when

- One PR on branch `effort/galavant-dev-variant`. `scripts/check-drift.sh` is green, headless
  `GalavantTests` pass, and both configurations build (`-configuration Debug` and `-configuration
  Release`, generic iOS, compile-only).
- The PR description has the Debug/Release identity table from test 2.
- **Escalate:** this touches identifiers and entitlements. The architect reviews, then hands the PR to
  Jon for merge.
- The completing PR:
  - adds a DONE-LOG entry;
  - marks this brief Done in `docs/efforts/README.md` and ADR-0050 accepted (status line);
  - adds to `docs/device-passes.md` under **Verification gates**: *Xcode Run on the iPhone: "Galavant
    Dev", with the DEV icon, installs **next to** TestFlight Galavant; both open their own libraries;
    the share sheet lists both; Galavant Dev's Settings shows "CloudKit Development"; Weather loads in
    Galavant Dev (WeatherKit on the new App ID);*
  - sets `docs/NEXT_UP.md` to `# Next Up` / `Nothing dispatched.`
