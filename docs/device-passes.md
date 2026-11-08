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
goes out only after it's imported to Development with `cktool` and the schema is deployed to Production (jon-platform
`docs/ios/persistence-and-sync.md` § Adding a synced table or column). A development build isn't enough: it creates only
the fields its rows fill. `testflight`'s schema gate refuses to archive unless Development and Production match, but it
passes when both lack a field.

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
  open, and check that every trailing toolbar item is there, including the AI menu. AI →
  Paste with an empty clipboard shows a warning, not nothing. Day 1 and day 6 pins and routes are
  clearly different colors on the map in light and dark mode. List sequence badges are neutral and
  readable. This replaces the brief's simulator-screenshot criteria, which were struck in the PR 189
  review. (The hero no longer collapses: see **Itinerary scroll freeze** below.)
- **Stay-grouped day lens (iPad):** on the Eastern France trip, check the one-strip layout and
  stay/day grouping; repeat on a trip with an unstayed arrival day. Confirm stay and day selection
  filter the canvas as expected and VoiceOver announces the full stay and date labels.
- **Stay-tap freeze (`stay-tap-freeze`).** On iPad and iPhone, tap each stay label on the Eastern France trip, then a day, then All: no freeze, no header flicker, and the list lands on the stay's first day. Check the selected stay label too: if its fill still renders dark rather than matching the selected day chip, that's a separate styling bug (brief § 4) to send back.
- **Launch-lock crash (`launch-lock-suspension`).** After the TestFlight build that carries it: no unexplained `0xdead10cc` in `testflight --feedback` over a week of normal use, including background pushes from Wendy's edits. If one appears, read the last expiration log line before it: `busy` is the accepted case, and `suspended` or no line at all is a question to raise. Send the architect a rough count of `busy` against `suspended` too. Leave Galavant in the background for several minutes while Wendy edits a trip, then open it: her edit arrives within a few seconds, and Settings → Sync reads "Up to date". Make an edit and leave at once: it reaches the other device without reopening. Two shares in a row from the share sheet both save. If Galavant ever closes by itself right after you open it, look in Console for "Bootstrap expired and database setup was interrupted". That clean exit won't show up as a crash in `testflight --feedback`. It's only expected on a launch in the background, so seeing it on a launch you started yourself is a question to raise, and so is a close with no such line. Read the bootstrap timings from Console (`migrate` and `makeSyncEngine`) and send them to the architect; if trigger setup is a large share, that's a question to raise.
- **Hand off purposes (`hand-off-purposes`).** On a trip, the toolbar menu reads AI with `sparkles`, and the three items show different icons. The Ideas toolbar has no Discuss, and its other items are all still there on iPad. Hand off → Summarize Conversation opens "Hand off · Summarize Conversation" and its brief copies. Copy a seed reply's JSON object alone (no `GV-SEED` line, no token) and tap the toolbar Paste: seed review opens with a "No GV-SEED line" note. A full reply with its token goes back into the session it came from. Candidate JSON through the same Paste still lands in candidate review. The Ideas list has no Seed from Conversation row.
- **Chat access setup (`chat-access` S2).** Jon's ops, once: create a `galavant` tunnel on the OpenAI Platform; run `scripts/install-mcp-helper` per `docs/chat-access-setup.md`; run `mcp-tunnel init galavant … --health-port 8082` and `install-agent galavant`; add the plugin in ChatGPT. If the TestFlight archive fails signing, enable iCloud Documents on both App IDs. Turn on Settings → Chat Access on the iPhone and iPad.
- **Chat access round trip (`chat-access` S2).** On the iPhone, Hand off → Get Recommendations, and paste the brief into a ChatGPT chat outside any Project. Ask for options and tell it to stage them: ChatGPT asks first, then a From Chat row reaches both devices with the trip name, the count, and a badge on Evaluate. On the iPad, tap it: the workspace opens on the set, and the options are under Consider. Tap back to Evaluate: the From Chat row is gone and the set is in the queue with the right count. Stage a second round from the same chat and tap it: they join the same set with no duplicates. Discard a third staged set: nothing changes on the trip. Right-click or long-press a staged row: Discard is there. Ask the chat to stage malformed JSON: it reports the error and nothing appears. On Wendy's phone, once the options sync, they appear under Consider, and Evaluate shows no From Chat section.
- **Chat access seeds (`chat-access` S3).** Reinstall the helper and refresh the connector. Paste the Hand off → Summarize Conversation brief into a planning chat and have it stage the seed. Tap the row in Evaluate and confirm the trip opens with seed review on iPad and iPhone. On iPhone, try with no trip open and with that trip already open. Dismiss the review and confirm the row stays. Tap again and import, then confirm the row goes. Repeat in a general chat that only mentioned some places and had no stays. Paste the same brief partway through, have it stage, then confirm the row arrives and commits. Tell the architect if ChatGPT had to resend or asked you to confirm twice so we can track when models drop the `GV-SEED` line. Verify a places-only seed without `GV-SEED` still opens through Paste. ([brief](efforts/archive/chat-access.md))
- **chat-access S4:** Reinstall the Galavant MCP helper; restart the tunnel and refresh the connector. Refresh updates export time and size. More backgrounding within 15 minutes writes nothing; background the app after 15 minutes and confirm the export time moves. Create a brand-new trip, then use Hand off and confirm its brief stages immediately. From a chat with a made-up trip UUID and no GV-HANDOFF token, confirm staging is rejected and the model is directed to list_trips. In a new ChatGPT chat with no brief, ask about a trip: it lists trips, reads one, reports the export's age and the right start date, and doesn't suggest places already ruled out. Stage options from that chat, and the row arrives in Evaluate. ([brief](efforts/archive/chat-access.md))
- **taste-notes:** Verify note create/edit/delete, deletion survival, conversation import review and duplicate detection, Wendy-device sync, and taste-note context in trip briefs, frontier chat, and get_trip on iPhone and iPad. ([brief](efforts/archive/taste-notes.md))
- **Itinerary scroll freeze (`itinerary-scroll-freeze`).** The hero and Add Ideas layout passed on the iPad's Eastern France trip on 2026-11-07. Still owed on the iPad: Bavaria/Dolemites scrolls too; tap a day chip, then a stay label: no freeze, and the list lands on the stay's first day; the Unsplash credit links still open. On the iPhone: the itinerary and day lens still scroll, with no hero. That pass was on a Dev build before the final cleanup, so run these on the TestFlight build.
- **Plan snapshot (`plan-snapshot`).** On the iPad, TestFlight build, on Eastern France and then Bavaria/Dolemites. Flick the whole-trip itinerary from top to bottom and back: it keeps moving and never locks up. Tap a stay label, a day chip, then All: no freeze, and the list lands where it should. Rows still show what they did: sequence numbers, connectors filling in their times, the "N options" title and controls on an alternatives stop, and the warning triangle on a home base that overlaps another stay. Under a day lens, drag an Anytime stop to a new position and it stays there. From a stop's menu, use Move Earlier and Move Later: they're disabled on the first and last Anytime stop and update after a move, and VoiceOver's actions on the row agree. Rename a stop's idea: the itinerary shows the new name without reopening. Edit a stop on Wendy's phone: it arrives without reopening. Change the trip's length: days appear or go. If either trip still hitches, record a Time Profiler trace on a Dev build and send it to the architect. Don't add scroll tracking to test it.
- **Idea dossier (`idea-dossier`).** On the iPad, then the iPhone, TestFlight build. In Ideas, tap a restaurant with a Michelin rating, photos, and a taste note: the dossier opens, not the editor, with the header photo sharp and the accolade, both of your interests, and the note above the fold. On the iPad the map stays beside it with the pin selected, and Back returns to the list where you left it. Tap a map pin: same dossier. Tap a hotel: its notes lead. Set your interest from the dossier, and the Ideas row shows it after Back. Add a taste note from the dossier: it appears there and in Settings → Taste Notes. Tap Edit, change the description, and Save: the dossier shows the change. Open a photo from the strip: it shows full screen. In a trip, open a stop's info: the same dossier, with "On the Itinerary" and a sharp header. Ask Wendy to rate something you have open: her level arrives without reopening. ([brief](efforts/archive/idea-dossier.md))
- **Region guide (`region-guide`).** On the iPad, TestFlight build. In Ideas, pick a region you've collected restaurants in and tap Guide: it opens on Dining for that region. Sections follow the accolades as the guides wrote them, and unrated places sit last. Mark one Do Not Do from its dossier: it leaves All, and the Not for Me count goes up. Switch to Hotels: the cards lead with your notes. Try Want to Go and Noted. Tap a pin, then a card: the same dossier, with the map still beside it. Tap a restaurant on the map you haven't saved: the capture form opens. Then on the iPhone, open the guide and flip to the map. **Then judge it, and write the answers in the PR or to the architect:** Did you browse past what you came for? Are the sections the right cut, or would you rather group by area or by interest? Is Noted useful, or do you want a real Favorites? Should the Ideas list hide Do Not Do too? What did you reach for that isn't there? ([brief](efforts/archive/region-guide.md))
- **Dossier over the map (`guide-dossier-panel`).** On the iPad, TestFlight build. Open the Guide for a region with restaurants. Tap a card: the dossier floats over the right side of the map, and the list stays put. Tap three more cards, then a pin: each one swaps in with no back step. Pan the map with the panel open. Tap Edit, save, and close. Do the same in Ideas. On the iPhone, tap a card: a half-height sheet. Tap another card behind it: it swaps. Switch to the map with the sheet at half height, tap an Apple Maps place that isn't saved, then tap Add: its card opens, and then the capture form. Pull it up to full height, then close it. Open a stop from a trip and from Today: they look exactly as before. **Then judge:** Is the panel wide enough to read? Does it cover pins you wanted to see? ([brief](efforts/archive/guide-dossier-panel.md))
- **Trip lens (`guide-trip-lens`).** On the iPad, TestFlight build. Open the Guide on a region your next trip has days in. The strip shows those days' lunches and dinners, and matches the trip's itinerary: booked ones green, a slot with options amber with its count, open ones dashed. Cards on the trip say where. Switch to Hotels: the nights, with a stay spanning its nights and any night with no stay marked. Fold the strip, leave, and come back: still folded. Pick a region with no trip days: no strip. On the iPhone, the strip is a row of day cards. **Then judge:** Does the strip earn its height above the cards? Is anything you'd want to know about a day missing? ([brief](efforts/archive/guide-trip-lens.md))
- **Filling slots from the guide (`guide-slot-filling`).** On the iPad, TestFlight build, on a real upcoming trip. In the Guide's Dining strip, open a restaurant and Add to Trip: an open lunch. The cell fills, and the trip's itinerary shows it on that day. Add a second restaurant to that same slot: it reads "2 options", and the itinerary's route doesn't change. Tap the cell: both options, one Active. Make the other active, then take one out: the slot keeps the rest. Find a place closed one of your days: that row says why. On Hotels, give an open night a hotel with Stay here. Then on the iPhone, add one place from the sheet. Open the trip and check everything you did is there. **Then judge:** Did you plan meals here without going back to the trip? What did you still have to go back for? Do you want candidate hotels (ADR-0053 OQ5)? ([brief](efforts/archive/guide-slot-filling.md))
- **day-design-sheet:** In Shape Trip, set a day’s region, zone, and summary; tap its itinerary header and confirm the sheet opens on that day with the summary focused. Confirm the header shows date, region, zone, and summary without menus, Add a stop is a small bordered button, and meal summaries appear in the guide on iPad and iPhone. ([brief](efforts/archive/day-design-sheet.md))

## Held

`taste-notes` is still ahead. Its gate is written ahead of the work, so it moves to **Owed now** when
its PR lands.

- **Schema deploy: `trips.visitedRolledUpAt`, `calendarPlanRepairs.resolvedAt`, `ideaEvaluations.lastVerifiedAt` (held ops).** None of these was in either CloudKit environment, and on 2026-11-07 a trip title edit on TestFlight didn't reach the other device. They were imported with `cktool` and deployed to Production that day, alongside `tasteNotes`, and a new edit then synced. Builds carrying the column (TestFlight 0.2.0-486 onward) may have blocked earlier `Trip` saves too. From reading the code, those edits sync only when that record next changes, so compare trips on every device, including Wendy's phone, and re-save any that differ from the device with the right version. Then remove this line.
- **Taste notes (`taste-notes`).** After the schema deploy, on iPhone and iPad: add a note about a saved restaurant, a note about a hotel you never saved (typed name), and a general note with no place. All three appear in Settings → Taste Notes, and the first also appears on that idea. Delete that idea: the note stays and still names the place. Wendy's phone shows all three once they sync, and she can add her own. Copy a Get Recommendations brief: it carries the notes.
- **Taste notes import (`taste-notes`).** Settings → Taste Notes → Import from Conversation → Copy Prompt, and run it in a real ChatGPT conversation about a restaurant or hotel. Paste the reply: nothing starts selected, summaries are labeled as ChatGPT's, and a place you've saved links to its idea. Keep some, edit one, and paste again: the kept ones read Already saved. Paste malformed text: you get a visible error, and nothing changes. Judge whether the proposed notes are actually worth keeping; that's what this gate is for.

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
- On a trip, AI → Hand off → Summarize Conversation → paste the brief into the Denmark conversation → paste the
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
  then run AI → Ask now and a recommendation brief and confirm the taste lines are in the prompt.
- On a device or simulator with no identity, open Settings → Taste Profile: the overlay section
  explains and links to Planners. Mark yourself **This is me**, go back, and the overlay field appears.
