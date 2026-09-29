# Device passes & held gates

Jon's checklist: real-device and distribution gates. **Not executor work; the executor never
reads this file.** `NEXT_UP.md`'s **Owed** line points here. Moved from `CURRENT_HANDOFF.md` on
2026-09-29 (jon-platform ADR-0005). When a gate clears, delete it and note it in `DONE-LOG.md`.

## Verification gates (decision gates, not a build queue)

- **M5 real-device gate.** TestFlight on both phones: travel-party share acceptance,
  two-way CloudKit changes, image/BLOB round-trips, pinned-reservation behavior.
  Checklist: `docs/milestones/M5-EXECUTION.md`. (The old "manual Calendar export on both devices"
  check was dropped per ADR-0034.)
- **M4 CloudKit BLOB sync** still needs two-real-device verification (ADR-0009 §4).
- **Bounded-intelligence gates.** `docs/milestones/M6-EXECUTION.md`: wire `TravelProfile`; review
  chat's direct `create_idea` durable-write authority. Decision gates, not an
  implementation queue. House memory marks the M6 AI thread paused pending yes-chef while
  M5 dogfooding is the active thread.
