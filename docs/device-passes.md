# Device passes & held gates

Jon's checklist: real-device passes owed by merged work, plus held ops steps and decision gates. `NEXT_UP.md`'s
**Owed** line points here. The executor never reads this file; it only appends its own gate through `closeout`.

- **Adding:** `closeout` puts a new gate at the end of **Owed now**, so that list runs oldest to newest. Don't add
  at the top. A gate written before its work lands goes in **Held**.
- **Clearing:** when a pass clears, the architect or Jon deletes its line and adds a note to `DONE-LOG.md`. Telling
  the architect what cleared is enough.
- **Held:** waiting on an ops step or on other work. Move a line to **Owed now** when it can be run.
- **Older:** nothing new goes here. These predate 2026-10-30, and some may no longer apply, so each one gets run, or
  retired by Jon.

**Standing state (not a task):** Galavant runs from TestFlight on CloudKit Production. Phases 1–5 of
[`PROD-CUTOVER.md`](PROD-CUTOVER.md) finished on 2026-10-08, and Wendy installed from TestFlight and accepted Jon's
share (she joined 2026-10-18, per the share sheet). What's left of Phase 6 is the M5 gate below. Debug builds install
as Galavant Dev, on CloudKit Development.

**Standing rule (schema deploy before TestFlight):** a build that adds a synced table or column, or first writes one,
goes out only after a development build has pushed it and the schema is deployed to Production. `testflight`'s schema
gate enforces this: it refuses to archive unless Development and Production match.

## Owed now

- **M5 real-device gate.** Phase 6 of `PROD-CUTOVER.md`. TestFlight on both phones, on Production:
  share acceptance passed (Wendy joined 2026-10-18). Still owed: two-way CloudKit changes (Wendy creates, edits and
  deletes; Jon sees it, and back), image/BLOB round-trips, pinned-reservation behavior.
  Checklist: `docs/milestones/archive/M5-EXECUTION.md`. (The old "manual Calendar export on both devices"
  check was dropped per ADR-0034.)
- **M4 CloudKit BLOB sync** (ADR-0009 §4): one direction passed 2026-10-08, when the fresh iPad pulled
  the library's images and documents from Production. The round trip (add an image on one device, see it
  on the other) is part of the M5 gate.
- **Sync failure status and retry.** On both phones and the iPad, Settings → Sync reads "Up to date" on
  the real library (any count here is a finding: report it, don't retry it away). Then, in Airplane
  mode, edit an idea and wait past 30 minutes: the row reads "1 item hasn't synced" and the detail
  names the idea. Turn the network back on: it uploads and returns to "Up to date", with or without
  Retry. The not-applied count is zero, or the detail says what's stuck.
- Paste a recommendation reply that wraps its places in `{"summary": …, "places": […]}`: the review
  shows **Chat also said** with the summary; choose **Save to Trip Documents** and confirm the document
  appears on the other device. In **Ruled out**, choose **Find on Map** on an unresolved row: the place
  joins the Ideas pool and the row stays ruled out.
- **Visited roll-up.** Open the app with a past trip in the library: its scheduled, not-skipped places
  show Visited in Ideas, and its itinerary still shows every stop. Clear Visited on one of them, relaunch
  on both devices, and it stays cleared.
- **iCloud identity readings (ADR-0051 Slice 0), on Jon's phone and on Wendy's:** TestFlight 0.2.0-486 and later carry the readout. Settings → Planners → iCloud identity → Copy, and send both readings to the architect, who records OQ1–OQ3 in ADR-0051. Plus one reading from Galavant Dev on Jon's phone, for OQ3. Wendy only reads; nothing here changes the share.
- **Planning chrome alignment (PR 189), on the iPad:** open a dated trip with the chat inspector
  open, and check that every trailing toolbar item is there, including the Hand off menu. Hand off →
  Paste with an empty clipboard shows a warning, not nothing. Day 1 and day 6 pins and routes are
  clearly different colors on the map in light and dark mode. List sequence badges are neutral and
  readable. Scroll the itinerary: the hero image and its photo credit collapse together and come back
  at the top. This replaces the brief's simulator-screenshot criteria, which were struck in the PR 189
  review.
- **Stay-grouped day lens (iPad):** on the Eastern France trip, check the one-strip layout and
  stay/day grouping; repeat on a trip with an unstayed arrival day. Confirm stay and day selection
  filter the canvas as expected and VoiceOver announces the full stay and date labels.
- **Stay-tap freeze (`stay-tap-freeze`).** On iPad and iPhone, tap each stay label on the Eastern France trip, then a day, then All: no freeze, no header flicker, and the list lands on the stay's first day. Check the selected stay label too: if its fill still renders dark rather than matching the selected day chip, that's a separate styling bug (brief § 4) to send back.

## Held

`hand-off-purposes`, `chat-access` and `taste-notes` aren't built yet, and `launch-lock-suspension` is still in draft (#197). Their
gates are written ahead of the work, so each moves to **Owed now** when its PR lands.

- **Schema deploy: `trips.visitedRolledUpAt` (held ops).** A development build with sync on pushes it once a past trip rolls up, then deploy the schema before the next TestFlight build. TestFlight builds 0.2.0-486 through -494 carry the column, so this may be done. Confirm it in the console, then remove this line.
- **Hand off purposes (`hand-off-purposes`).** On a trip, Hand off → Summarize Conversation opens "Hand off · Summarize Conversation" and its brief copies. Copy a seed reply's JSON object alone (no `GV-SEED` line, no token) and tap the toolbar Paste: seed review opens with a "No GV-SEED line" note. A full reply with its token goes back into the session it came from. Candidate JSON through the same Paste still lands in candidate review. The Ideas list has no Seed from Conversation row.
- **Chat access setup (`chat-access` S2).** Jon's ops, once: create a `galavant` tunnel on the OpenAI Platform; run `scripts/install-mcp-helper` per `docs/chat-access-setup.md`; run `mcp-tunnel init galavant … --health-port 8082` and `install-agent galavant`; add the plugin in ChatGPT. If the TestFlight archive fails signing, enable iCloud Documents on both App IDs. Turn on Settings → Chat Access on the iPhone and iPad.
- **Chat access round trip (`chat-access` S2).** On the iPhone, Hand off → Get Recommendations, and paste the brief into a ChatGPT chat outside any Project. Ask for options and tell it to stage them: ChatGPT asks first, then a From Chat row reaches both devices with the trip name, the count, and a badge on Evaluate. On the iPad, tap it: the workspace opens on the set, and the options are under Consider. Stage a second round from the same chat and tap it: they join the same set with no duplicates. Discard a third staged set: nothing changes on the trip. Ask the chat to stage malformed JSON: it reports the error and nothing appears. On Wendy's phone, once the options sync, they appear under Consider, and Evaluate shows no From Chat section.
- **Chat access seeds (`chat-access` S3).** Paste the Hand off → Summarize Conversation brief into a planning chat and have it stage the seed. Tap the row: the trip opens with seed review, on iPad and iPhone. Dismiss it: the row stays. Tap again and commit: the row goes.
- **Chat access read tools (`chat-access` S4).** In a new ChatGPT chat with no brief, ask about a trip: it lists trips, reads one, reports the export's age, and doesn't suggest places already ruled out. Stage options from that chat, and the row arrives as above.
- **Taste notes (`taste-notes`).** After the schema deploy, on iPhone and iPad: add a note about a saved restaurant, a note about a hotel you never saved (typed name), and a general note with no place. All three appear in Settings → Taste Notes, and the first also appears on that idea. Delete that idea: the note stays and still names the place. Wendy's phone shows all three once they sync, and she can add her own. Copy a Get Recommendations brief: it carries the notes.
- **Taste notes import (`taste-notes`).** Settings → Taste Notes → Import from Conversation → Copy Prompt, and run it in a real ChatGPT conversation about a restaurant or hotel. Paste the reply: nothing starts selected, summaries are labeled as ChatGPT's, and a place you've saved links to its idea. Keep some, edit one, and paste again: the kept ones read Already saved. Paste malformed text: you get a visible error, and nothing changes. Judge whether the proposed notes are actually worth keeping; that's what this gate is for.
- **Launch-lock crash (`launch-lock-suspension`).** After the TestFlight build that carries it: no new `0xdead10cc` in `testflight --feedback` over a week of normal use, including background pushes from Wendy's edits. Leave Galavant in the background for several minutes while Wendy edits a trip, then open it: her edit arrives within a few seconds, and Settings → Sync reads "Up to date". Make an edit and leave at once: it reaches the other device without reopening. Two shares in a row from the share sheet both save. Read the bootstrap timings from Console (`migrate` and `makeSyncEngine`) and send them to the architect; if trigger setup is a large share, that's a question to raise.

## Older

- **M7 calendar dogfood** (ADR-0034, still *proposed*; ADR-0041 amendments implemented, pending
  device verification). Run Parts 1–3 of [`M7-DOGFOOD.md`](milestones/archive/M7-DOGFOOD.md) on device;
  when it passes, flip ADR-0034 to accepted.
- **Bounded-intelligence gates.** `docs/milestones/archive/M6-EXECUTION.md`: review chat's direct
  `create_idea` durable-write authority. A decision gate, not an implementation queue. (`TravelProfile`
  was decided 2026-10-08 and is queued as an effort: the ChatGPT briefs and in-app chat read it.)
- **Evaluate re-paste flow.** Confirm the paste-confirmation wording and re-paste flow on device.
- Re-copy the recommendation project instructions from Settings, confirm a "book ahead" hint seeds To book, and check the Today card on device.
- On a live trip day, check the Today map card's framing with and without location; confirm a preview day doesn't frame your position and that pin taps open the idea.
- With Today open on a live day across midnight (or a clock change), confirm the map keeps your position in frame on the new day.
- On one device, add a trip document and confirm it appears on the other after sync; delete the trip and confirm the document is removed.
- Rule out a place on one device and confirm it appears under Ruled out on the other.
- Re-copy the project instructions (now v2) into the ChatGPT project.
- On a trip, Seed from Conversation → paste the brief into the Denmark conversation → paste the
  reply back → review → Import; check the founding document, stays, rings and Ruled out on iPhone
  and iPad.
- Seed the Denmark conversation into a trip that shares a few places with the pool: saved-idea matches
  badge correctly (including business-listing names), "Confirm Obvious Matches" resolves the expected
  rows, deferred places appear on the Ideas map, research notes show on resolved places, and Evaluate
  opens the leftovers.
- Move a linked trip event to another trip day in Calendar, run Reconcile Calendar, and confirm it
  shows as a linked match (not "No Itinerary Match") with the Plan Repair at the top of the sheet.
- **Settings → Library → Tags:** delete the unused demo tags; tag an idea and confirm the tag shows on
  its row; create the same tag name on iPhone and iPad (one offline) and confirm one tag remains after
  sync and opening Settings → Tags. Rename a tag onto an existing name (different case) and confirm
  the alert says it will merge before you save. SwiftUI may not refresh an alert message while you
  type, so if the note doesn't appear, say so.
- On iPad and iPhone, Ideas → Denmark: tap Food, then Food + Stay, then Other; confirm the list and
  map pins narrow together. Tap Scheduled, then Not scheduled. Switch to All and confirm the stage
  capsules disappear and the kind selection stays.
- **Travel profile on TestFlight:** edit the profile on one device and confirm it reaches the other;
  then run Discuss and a recommendation brief and confirm the taste lines are in the prompt.
- On a device or simulator with no identity, open Settings → Taste Profile: the overlay section
  explains and links to Planners. Mark yourself **This is me**, go back, and the overlay field appears.
