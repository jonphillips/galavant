# Device passes & held gates

Jon's checklist: real-device and distribution gates. **Not executor work; the executor never
reads this file.** `NEXT_UP.md`'s **Owed** line points here. Moved from `CURRENT_HANDOFF.md` on
2026-09-29 (jon-platform ADR-0005). When a gate clears, delete it and note it in `DONE-LOG.md`.

- **TestFlight release workflow — held gate.**
  - **One-time:** follow [jon-platform's TestFlight runbook](https://github.com/jonphillips/jon-platform/blob/main/docs/ios/testflight.md) § One-time setup
    (the `cktool` token, `asc` installed and pinned, the API key, and the symlink). From clean `main`,
    `testflight --dry-run` must report no setup missing.
  - **First real run:** run `testflight` from clean `main`. Confirm the schema gate and build-number
    guard pass; the export verification table is all pass; processing finishes before the build is
    tagged; What to Test appears in TestFlight on the phone; and `testflight --feedback` writes a file.
- **Production cutover — Phase 6 left.** Phases 1–5 done 2026-10-08: TestFlight on Production, iPhone
  carried the library, a fresh iPad pulled it. Remaining: add Wendy as an internal TestFlight tester,
  then run Phase 6 of [`PROD-CUTOVER.md`](PROD-CUTOVER.md) (she installs clean, accepts the travel-party
  share), which is the M5 gate below.
- **Schema deploy before TestFlight (standing).** A build that adds a synced table or column, or first
  writes one, goes out only after a development build has pushed it and the schema is deployed to
  Production. For `travelProfiles`: on a development build with sync on, save a household profile and
  your overlay (so `plannerID` holds a value). In the CloudKit console, confirm `travelProfiles` has
  `travelPartyID`, `plannerID` and `preferences`. Deploy the schema to Production, then archive the
  TestFlight build. On TestFlight, edit the profile on one device and confirm it reaches the other;
  then run Discuss and a recommendation brief and confirm the taste lines are in the prompt.
- **Galavant Dev portal setup (one-time, before the `galavant-dev-variant` device pass, ADR-0050).**
  Register App IDs `com.jonphillips.galavant.dev` and `com.jonphillips.galavant.dev.share` and the app
  group `group.com.jonphillips.galavant.dev`; assign the existing container `iCloud.com.jonphillips.galavant`
  to both. Enable **WeatherKit** on the `.dev` app ID in **both** Capabilities and App Services.
  Automatic signing creates most of it on the first Run; WeatherKit it won't.

## Verification gates (decision gates, not a build queue)

- **Galavant Dev:** Xcode Run on the iPhone: "Galavant Dev", with the DEV icon, installs **next to** TestFlight Galavant; both open their own libraries; the share sheet lists both; Galavant Dev's Settings shows "CloudKit Development"; Weather loads in Galavant Dev (WeatherKit on the new App ID).
- Move a linked trip event to another trip day in Calendar, run Reconcile Calendar, and confirm it
  shows as a linked match (not "No Itinerary Match") with the Plan Repair at the top of the sheet.
- On one device, add a trip document and confirm it appears on the other after sync; delete the trip and confirm the document is removed.
- Rule out a place on one device and confirm it appears under Ruled out on the other.
- With Today open on a live day across midnight (or a clock change), confirm the map keeps your position in frame on the new day.
- On a live trip day, check the Today map card's framing with and without location; confirm a preview day doesn't frame your position and that pin taps open the idea.
- Re-copy the recommendation project instructions from Settings, confirm a "book ahead" hint seeds To book, and check the Today card on device.
- **Evaluate re-paste flow.** Confirm the paste-confirmation wording and re-paste flow on device.
- **Settings → Library → Tags:** delete the unused demo tags; tag an idea and confirm the tag shows on
  its row; create the same tag name on iPhone and iPad (one offline) and confirm one tag remains after
  sync and opening Settings → Tags. Rename a tag onto an existing name (different case) and confirm
  the alert says it will merge before you save. SwiftUI may not refresh an alert message while you
  type, so if the note doesn't appear, say so.
- On a device or simulator with no identity, open Settings → Taste Profile: the overlay section
  explains and links to Planners. Mark yourself **This is me**, go back, and the overlay field appears.
- On iPad and iPhone, Ideas → Denmark: tap Food, then Food + Stay, then Other; confirm the list and
  map pins narrow together. Tap Scheduled, then Not scheduled. Switch to All and confirm the stage
  capsules disappear and the kind selection stays.
- Re-copy the project instructions (now v2) into the ChatGPT project.
- On a trip, Seed from Conversation → paste the brief into the Denmark conversation → paste the
  reply back → review → Import; check the founding document, stays, rings and Ruled out on iPhone
  and iPad.
- Seed the Denmark conversation into a trip that shares a few places with the pool: saved-idea matches
  badge correctly (including business-listing names), "Confirm Obvious Matches" resolves the expected
  rows, deferred places appear on the Ideas map, research notes show on resolved places, and Evaluate
  opens the leftovers.
- **M5 real-device gate.** Phase 6 of `PROD-CUTOVER.md`. TestFlight on both phones, on Production:
  travel-party share acceptance, two-way CloudKit changes, image/BLOB round-trips, pinned-reservation behavior.
  Checklist: `docs/milestones/M5-EXECUTION.md`. (The old "manual Calendar export on both devices"
  check was dropped per ADR-0034.)
- **M4 CloudKit BLOB sync** (ADR-0009 §4): one direction passed 2026-10-08, when the fresh iPad pulled
  the library's images and documents from Production. The round trip (add an image on one device, see it
  on the other) is part of the M5 gate.
- **Bounded-intelligence gates.** `docs/milestones/M6-EXECUTION.md`: review chat's direct
  `create_idea` durable-write authority. A decision gate, not an implementation queue. (`TravelProfile`
  was decided 2026-10-08 and is queued as an effort: the ChatGPT briefs and in-app chat read it.)
