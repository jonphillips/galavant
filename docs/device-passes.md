# Device passes & held gates

Jon's checklist: real-device and distribution gates. **Not executor work; the executor never
reads this file.** `NEXT_UP.md`'s **Owed** line points here. Moved from `CURRENT_HANDOFF.md` on
2026-09-29 (jon-platform ADR-0005). When a gate clears, delete it and note it in `DONE-LOG.md`.

- iPhone, a trip with ideas, bottom sheet up: each of Add Ideas, Documents, Evaluate
  Recommendations, Recommend, N to book, Start Day, Reconcile Calendar (dated trip), Discuss,
  Shape Trip and Today opens, and dismissing returns to the sheet at its detent. Repeat on iPad
  (no regressions).
- iPhone, an empty trip: the summary, Documents and Add rows are visible and tappable, with the
  empty message below them.

## Verification gates (decision gates, not a build queue)

- On one device, add a trip document and confirm it appears on the other after sync; delete the trip and confirm the document is removed.
- Rule out a place on one device and confirm it appears under Ruled out on the other.
- Before the next TestFlight build, promote the `tripDocuments` record type to the CloudKit Production schema.
- With Today open on a live day across midnight (or a clock change), confirm the map keeps your position in frame on the new day.
- On a live trip day, check the Today map card's framing with and without location; confirm a preview day doesn't frame your position and that pin taps open the idea.
- Re-copy the recommendation project instructions from Settings, confirm a "book ahead" hint seeds To book, and check the Today card on device.
- **Evaluate re-paste flow.** Confirm the paste-confirmation wording and re-paste flow on device.
- **M5 real-device gate.** TestFlight on both phones: travel-party share acceptance,
  two-way CloudKit changes, image/BLOB round-trips, pinned-reservation behavior.
  Checklist: `docs/milestones/M5-EXECUTION.md`. (The old "manual Calendar export on both devices"
  check was dropped per ADR-0034.)
- **M4 CloudKit BLOB sync** still needs two-real-device verification (ADR-0009 §4).
- **Bounded-intelligence gates.** `docs/milestones/M6-EXECUTION.md`: wire `TravelProfile`; review
  chat's direct `create_idea` durable-write authority. Decision gates, not an
  implementation queue. House memory marks the M6 AI thread paused pending yes-chef while
  M5 dogfooding is the active thread.
