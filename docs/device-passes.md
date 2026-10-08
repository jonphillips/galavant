# Device passes & held gates

Jon's checklist: real-device and distribution gates. **Not executor work; the executor never
reads this file.** `NEXT_UP.md`'s **Owed** line points here. Moved from `CURRENT_HANDOFF.md` on
2026-09-29 (jon-platform ADR-0005). When a gate clears, delete it and note it in `DONE-LOG.md`.

- **Production cutover — Phase 6 left.** Phases 1–5 done 2026-10-08: TestFlight on Production, iPhone
  carried the library, a fresh iPad pulled it. Remaining: add Wendy as an internal TestFlight tester,
  then run Phase 6 of [`PROD-CUTOVER.md`](PROD-CUTOVER.md) (she installs clean, accepts the travel-party
  share), which is the M5 gate below.
- **Schema deploy before TestFlight (standing).** A build that adds a synced table or column, or first
  writes one, goes out only after a development build has pushed it and the schema is deployed to
  Production. The dispatch's **Owed** line names the table. Next case: `travelProfiles` (the travel
  profile effort).
## Verification gates (decision gates, not a build queue)

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
  sync and opening Settings → Tags.
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
