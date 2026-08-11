# M5 (Polish & distribution) — real-device verification

The daily-use slices have shipped and their package-level behavior is covered in the
repository:

- **Sync health:** `SettingsScreen` presents `SyncHealthModel` / `SyncStatusSection`.
- **Pinned reservations:** `TripIdea.pinnedDate` and `ReservationPin` preserve an
  absolute reservation date while `Trip.update` re-derives the day number.
- **Calendar export (shipped, then superseded as the direction):** a dated trip has an
  explicit **Sync to Calendar** action that reconciles into a device-local
  `Galavant: <trip>` EventKit calendar.

**The one-way calendar boundary is superseded by ADR-0034.** The calendar story is now
*ingest and reconcile* (roadmap M7), not *mirror out*. The shipped export code is
retained but demoted — it becomes the guts of a possible future deliberate "Add to
Shared Calendar" action, not the calendar milestone. **Calendar is therefore removed
from the M5 gate below** (Jon's call, 2026-08-10: the shipped export must not gate this
work, and the real-device pass must not gate the new direction). The rest of the M5
spine — two-device CloudKit and image/BLOB round-trips — is independent and still
valid.

## The remaining M5 spine

This is a real-device/distribution milestone now, not another implementation batch.
Complete these checks on a TestFlight build:

1. **Two-device CloudKit:** install on Jon's phone and his wife's phone, accept the
   travel-party share, then prove creations, edits, and deletions sync in both
   directions. Use the sync-health surface to distinguish waiting/error/local-only
   from a healthy state.
2. **CloudKit images/BLOBs:** capture or create an idea with a header image on one
   device, wait for sync, and verify the other device receives and displays the image
   correctly. This closes the M4 image-storage verification still deferred in
   ADR-0009.
3. **Pinned reservation:** pin a dated reservation, move the trip start date, and
   confirm the reservation keeps its calendar date on both devices after sync.
4. **Distribution/dogfooding:** keep the TestFlight build on Jon's wife's phone for
   normal planning use. Record any breakage as a concrete follow-up rather than
   assuming the simulator or one-device path covers it.

*(The former "Calendar on both devices" export check was removed per ADR-0034 — the
one-way export is no longer the calendar direction. Calendar behavior is verified
under the M7 slices instead.)*

## After the gate

Do not create an M5½ feature batch. Optional polish—weather, platform refinements,
or further trip-header work—remains normal backlog. The next product decisions after
the verification spine are the small, evidenced M6 questions in
`docs/M6-EXECUTION.md`, beginning with wiring the existing `TravelProfile` or
reviewing chat's direct durable-write authority.
