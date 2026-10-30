# Device passes & held gates

Jon's checklist: real-device and distribution gates. **Not executor work; the executor never
reads this file.** `NEXT_UP.md`'s **Owed** line points here. Moved from `CURRENT_HANDOFF.md` on
2026-09-29 (jon-platform ADR-0005). When a gate clears, delete it and note it in `DONE-LOG.md`.

- **Production cutover — the M5 gate left.** Phases 1–5 done 2026-10-08. Wendy installed from
  TestFlight and accepted Jon's share (she joined 2026-10-18, per the share sheet). What's left of Phase 6 of [`PROD-CUTOVER.md`](PROD-CUTOVER.md)
  is the M5 gate below.
- **Schema deploy before TestFlight (standing).** A build that adds a synced table or column, or first
  writes one, goes out only after a development build has pushed it and the schema is deployed to
  Production. `testflight`'s schema gate enforces this: it refuses to archive unless Development and
  Production match. Pending: `trips.visitedRolledUpAt`; a development build with sync on pushes it once
  a past trip rolls up, then deploy the schema before the next TestFlight build.

## Verification gates (decision gates, not a build queue)

- **After the next TestFlight build, on Jon's phone and on Wendy's:** Settings → Planners → iCloud identity → Copy, and send both readings to the architect, who records OQ1–OQ3 in ADR-0051. Plus one reading from Galavant Dev on Jon's phone, for OQ3. Wendy only reads; nothing here changes the share.
- **Visited roll-up.** Open the app with a past trip in the library: its scheduled, not-skipped places
  show Visited in Ideas, and its itinerary still shows every stop. Clear Visited on one of them, relaunch
  on both devices, and it stays cleared.
- **Sync failure status and retry.** On both phones and the iPad, Settings → Sync reads "Up to date" on
  the real library (any count here is a finding: report it, don't retry it away). Then, in Airplane
  mode, edit an idea and wait past 30 minutes: the row reads "1 item hasn't synced" and the detail
  names the idea. Turn the network back on: it uploads and returns to "Up to date", with or without
  Retry. The not-applied count is zero, or the detail says what's stuck.
- **Travel profile on TestFlight:** edit the profile on one device and confirm it reaches the other;
  then run Discuss and a recommendation brief and confirm the taste lines are in the prompt.
- Move a linked trip event to another trip day in Calendar, run Reconcile Calendar, and confirm it
  shows as a linked match (not "No Itinerary Match") with the Plan Repair at the top of the sheet.
- On one device, add a trip document and confirm it appears on the other after sync; delete the trip and confirm the document is removed.
- Rule out a place on one device and confirm it appears under Ruled out on the other.
- With Today open on a live day across midnight (or a clock change), confirm the map keeps your position in frame on the new day.
- On a live trip day, check the Today map card's framing with and without location; confirm a preview day doesn't frame your position and that pin taps open the idea.
- Re-copy the recommendation project instructions from Settings, confirm a "book ahead" hint seeds To book, and check the Today card on device.
- **Evaluate re-paste flow.** Confirm the paste-confirmation wording and re-paste flow on device.
- Paste a recommendation reply that wraps its places in `{"summary": …, "places": […]}`: the review
  shows **Chat also said** with the summary; choose **Save to Trip Documents** and confirm the document
  appears on the other device. In **Ruled out**, choose **Find on Map** on an unresolved row: the place
  joins the Ideas pool and the row stays ruled out.
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
  share acceptance passed (Wendy joined 2026-10-18). Still owed: two-way CloudKit changes (Wendy creates, edits and
  deletes; Jon sees it, and back), image/BLOB round-trips, pinned-reservation behavior.
  Checklist: `docs/milestones/archive/M5-EXECUTION.md`. (The old "manual Calendar export on both devices"
  check was dropped per ADR-0034.)
- **M4 CloudKit BLOB sync** (ADR-0009 §4): one direction passed 2026-10-08, when the fresh iPad pulled
  the library's images and documents from Production. The round trip (add an image on one device, see it
  on the other) is part of the M5 gate.
- **M7 calendar dogfood** (ADR-0034, still *proposed*; ADR-0041 amendments implemented, pending
  device verification). Run Parts 1–3 of [`M7-DOGFOOD.md`](milestones/archive/M7-DOGFOOD.md) on device;
  when it passes, flip ADR-0034 to accepted.
- **Bounded-intelligence gates.** `docs/milestones/archive/M6-EXECUTION.md`: review chat's direct
  `create_idea` durable-write authority. A decision gate, not an implementation queue. (`TravelProfile`
  was decided 2026-10-08 and is queued as an effort: the ChatGPT briefs and in-app chat read it.)
