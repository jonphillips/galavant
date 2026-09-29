# Effort — booking status Scope 4: handoff "book ahead" hint + Today warning

**Status:** Dispatched (2026-09-29) · **Summary:** let a recommendation say "book ahead" so committing
it seeds `.toBook`, and warn on Today about anything still to book today or tomorrow. Implements
[ADR-0047](../decisions/0047-trip-booking-status.md) § Scope 4, on top of the shipped core, editors, and
display (#136–#138). One dispatch, two parts, one PR (they're small, and batching saves a dispatch).

No schema change: `TripIdea.bookingStatus` / `TripStay.bookingStatus` already exist. No sync change.

## Part A — the handoff hint

**Contract.** `TripCandidate` ([RecommendationHandoff.swift](../../GalavantLibrary/Sources/GalavantSchema/RecommendationHandoff.swift))
gains `bookAhead: Bool?`, coded as `book_ahead`. Add it to
`RecommendationHandoffContract.projectInstructions`: list it among the optional fields, add it to the
example object, and add one sentence of meaning: *"book_ahead is true when the place needs a
reservation or ticket bought in advance (timed entry, popular restaurant, show); omit it otherwise."*

- **Keep the marker at `v1`.** The field is optional and additive: an older project that never emits
  it still works, and an older build ignores it. Bumping the marker would break every existing
  project's instructions until Jon re-copies them. Jon re-copies anyway to *get* hints, but nothing
  should fail in the meantime.
- **The decoder must stay tolerant of this field.** `decodeReturn` is lossless-or-loud for the array,
  but an advisory hint must never fail a paste. Decode `true`/`false`; also accept the strings
  `"true"`/`"yes"` and `"false"`/`"no"` (case-insensitive), since models drift; anything else decodes as
  `nil`. Test each case, plus absence.

**Commit seeds, never overrides.** In `TripIdea.commit(candidate:into:in:)`:
- **Inserting a new row:** `bookingStatus = candidate.bookAhead == true ? .toBook : nil`. `false` or `nil`
  stores `nil`, so the ADR-0047 §2 inference still applies. A "no" from the model is not a decision.
- **Linking to an existing live row** (the #141 path): if that row's stored `bookingStatus` is `nil` and
  `bookAhead == true`, set it to `.toBook`. Never overwrite a stored value, since it's Jon's decision.
  Evidence (pin or confirmation number) still wins at resolve time, untouched.
- Stays aren't created from candidates, so there's no `TripStay` path.

**Review card.** In `RecommendationCandidateCardPresentation`, a candidate with `bookAhead == true`
shows a small "Book ahead" label (the outline ticket glyph from Slice 3, with text), so Jon sees it
before committing.

## Part B — Today warning

**Core (pure, tested).** `TodayProjection` ([TodayProjection.swift](../../GalavantLibrary/Sources/GalavantSchema/TodayProjection.swift))
gains `bookingsDue: [TripBookingItem]`: the `TripBookingRollup(plan:currentDay:)` **to-book** items
whose `day` is today's day number or tomorrow's, in the rollup's own order (soonest first). That
covers stops and stays: an unbooked bed tonight or tomorrow is the costliest miss (ADR-0047 §4).
Undecided items are **not** included, because deciding belongs in the trip's To Book sheet. Dayless
items aren't included either. Reuse the rollup; don't re-derive booking resolution.

Tests: a to-book stop today and one tomorrow are both included, one the day after is excluded; a
booked or evidence-pinned row is excluded; an undecided row is excluded; a to-book stay checking in
tomorrow is included; outside the trip, or on its last day, there's no crash and no "tomorrow" items.

**View.** Add a Today card, **"Still to book"**, shown only when `bookingsDue` is non-empty. Each row
shows its title, "today"/"tomorrow" and time, a **Book** link (the item's `bookingURL`, else the
idea's website, the same fallback as the To Book sheet), and **Mark booked**, which goes through the
existing `TripPlanningModel.setBookingStatus(_:for:)` path (or Today's equivalent write through the
same op). Don't add a new write path. Put it near the top of Today, after Next and before
Remaining. Follow `TodayCards.swift` styling.

## Done when

- Parts A and B as above, with package tests for decoding, both commit seeding paths, and
  `bookingsDue`.
- `scripts/check-drift.sh` is green, and headless `GalavantTests` pass if a Today model changed
  (`docs/verification.md`).
- The completing PR adds its DONE-LOG entry, sets `docs/NEXT_UP.md` to `Nothing dispatched.`, marks
  this brief Done in `docs/efforts/README.md`, and adds one line to `docs/device-passes.md`: *re-copy
  the recommendation project instructions from Settings, confirm a "book ahead" hint seeds To book,
  and check the Today card on device.*
