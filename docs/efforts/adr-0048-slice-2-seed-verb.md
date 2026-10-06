# Effort — ADR-0048 Slice 2: the seed verb (contract v2, decode, plan, bulk review, commit)

**Status:** Dispatched (2026-10-06) · **Summary:** the `seedTrip` handoff from
[ADR-0048](../decisions/0048-trip-seed-handoff.md): Galavant sends a seed brief, Jon pastes it into
the existing Chat conversation about the trip, and the narrative + `GV-SEED` + JSON reply becomes a
founding document plus a trip skeleton in **one reviewed tap**. **Every row lands freeform
(unresolved).** Matching against saved ideas and the map is Slice 3.

Read ADR-0048 D1–D8 and Appendices A–C first. This brief pins seams and edge rules; the ADR is the
spec.

## Schema / pure core (GalavantSchema, test-first)

### Contract v2

- `RecommendationHandoffTask.seedTrip = "seedTrip"`.
- `RecommendationHandoffContract.marker` → `v2`. Append ADR-0048 **Appendix A** to
  `projectInstructions` verbatim, after the existing candidate clause, which stays unchanged. Settings'
  copy button then serves v2 with no other change.
- **v1 still works.** A `candidatePlaces` paste stamped `GV-CONTRACT: v1` still imports, with
  ADR-0036 Amendment 1's older-marker warning. Add a test.
- `RecommendationHandoffContract.seedBrief(session:tripName:plan:)`, built like `brief`:
  - the header;
  - `Trip: <name>`;
  - the existing stop summary (stays and stops already on the trip), so a re-seed doesn't duplicate;
  - the existing `Already ruled out` section;
  - then `Ask: Seed this Galavant trip from our conversation so far, using the seed format in the
    project instructions. That format replaces the candidate-places format for this reply.`

  No trip notes, and no pool ideas (D1).

### `SeedReturn` decode (lossless-or-loud, ADR-0048 D2)

`SeedReturn.decode(_ text:)` takes the text after `HandoffRouting.route` and contract-marker stripping
(the existing paste path's first two steps).

- **Split** on the **last** line that is exactly `GV-SEED` after trimming whitespace. Text before it is
  the narrative, trimmed. Slice one JSON **object** from what follows: add an object slicer beside
  `jsonArraySlice` with the same string/escape-aware bracket matching, and normalize curly quotes as
  `TripCandidate.decodeReturn` does.
- **Errors** (typed, `LocalizedError`, nothing written): `missingSeedMarker`, `missingJSONObject`,
  `malformedJSON`, `emptySeed` (no bases **and** no places).
- **Narrative fallback:** if the narrative is empty, use top-level `summary`, then `trip.summary`;
  otherwise none.
- **Types:**
  - `SeedTrip`: `lengthDays`, `year`, `quarter`, `summary`.
  - `SeedBase`: `name` (required), `locality`, `searchHint`, `region`, `checkInDay`, `checkOutDay`
    (both required), `why`, `placeNotes`, `bookAhead`.
  - `SeedPlace`: every `TripCandidate` field plus `verdict`, `reason`, `futureTrip`, `placeNotes`,
    `group`. Expose a `TripCandidate` projection for reuse (matching, session payload).
  - Snake-case keys per Appendix A. Unknown keys are ignored.
  - **Lenient scalars,** as `TripCandidate` already does for `book_ahead`: `day_ref` and the day
    numbers accept a string or a number.
  - A base missing `name` or a valid day span (in-range, check-out after check-in, as
    `TripStay.isValidSpan`) is **dropped and reported** in a `SeedReturn.warnings` list shown in the
    review. Never silently.
- `SeedVerdict`: `core | considering | declined | deferred | unrecognized(String)`.
  `unrecognized` and missing both map to `.considering`; the review shows the original text.
- `IdeaKind(seedKind:)`: the synonym table from ADR-0048 D4. Exact case names first, then synonyms,
  else `nil`. Freeform `TripIdea` has **no kind column; don't add one.** In this slice the
  normalized kind is display-only in the review. Slice 3 passes it as the capture's fallback kind.

### `SeedPlan` (pure mapping, ADR-0048 D4/D5/D7)

`SeedPlan.make(from:trip:context:)`. `context` holds the trip's live `TripIdea`s + `ideasByID` (the
existing `recommendationMatchingContext`), its stays, the trip-attached `MapRegion`s, and the party's
`MapRegion`s. Output: ordered rows, each with an `include` default and a display reason.

- **Trip edits.**
  - Length: proposed when it differs. Default **on** only if `lengthInDays` is still the new-trip
    default (7).
  - Year/quarter: proposed when they differ. Default **on** only if both are `nil`. Never offered for
    a `.dated` trip; show the row disabled with "Trip has dates".
- **Base rows** → freeform `TripStay`s.
  - Title = `name`.
  - Note = `why`, then `About the place: <place_notes>` (blank-line separated, empty parts skipped).
  - `.toBook` when `book_ahead`.
  - Region: case- and diacritic-insensitive name match against trip-attached regions, else exactly
    one party region with that name, else none (OQ2; never create a region).
  - **Already on trip:** a stay with the same normalized title (`RecommendationCandidateIdentity.normalized`)
    and the same span. Default off.
- **Place rows.**
  - **Status:** `core` → `.shortlisted`; `considering`/unrecognized → `.considering`;
    `declined` → `.declined`; `deferred` → `.declined`.
  - **Note:** `why`, `fit`, `visit`, then `reason`. For deferred, the reason line reads
    `Deferred — <future_trip>: <reason>`. Then `About the place: <place_notes>`. Blank-line separated,
    empty parts skipped.
  - **`book_ahead`** → `.toBook` only on `.shortlisted`/`.considering` rows.
  - **`day_ref`:** display only.
  - **Already on trip:** `RecommendationCandidateSet.liveTripIdea` matches (it treats `.declined` as
    live since #149). Default off. If the existing row's status differs from the seed verdict, offer
    a **status update** row instead, default off, applied through `TripIdea.setStatus`.
- **Rings (ADR-0048 Amendment 1, this plan PR).**
  - A `group` with **≥ 2 included members whose verdict is `core` or `considering`** becomes a ring.
    Its members land as `.considering`, even when `core`, and the ring is formed with
    `TripIdea.chooseOne`, which accepts only `.considering` stops (ADR-0035).
  - Declined/deferred members keep their status and get no ring.
  - A group that ends up with < 2 live members is ignored, with a review note.
  - Recompute ring eligibility when the human toggles rows off.
- **Founding document:** the narrative (or its fallback) as `TripDocument` `origin: .seed`, titled
  `Founding conversation — <date>`. Check its size **before** any write: `tooLarge` stops the import
  loudly.

### Commit

`SeedPlan.commit(_:tripID:session:now:in:)`. **One** `database.write`, so a throw rolls everything back.

- Order: trip edits → stays (+ `TripDayRegion.setRegion` for each night in `TripStay.nights`) →
  places → rings → document.
- **Places:** add `TripIdea.commitSeedRow(…)` beside `commit(candidate:)` (that one is
  `.considering`-only). It inserts a freeform row with the given status, note and booking status.
  `.shortlisted` rows take `nextShortlistRank` in plan order. `.declined` rows are inserted directly.
- **Trip year/quarter:** go through `Trip.update(_:certainty:)` with the certainty Edit Trip produces
  for a targeted year/quarter. Length goes through `Trip.setLength`.
- **Session bookkeeping:** store the committed place rows' `TripCandidate` projections in the device-local
  `HandoffSession` via `storeRecommendationCandidates`, `link` each row, and set `.imported`. Slice 3
  and the ADR-0037 workspace open the seed's leftovers from this.

## App

- **Entry:** a **Seed from Conversation** row on the trip's Ideas page, next to Documents (the
  toolbar is full).
- **Presentation:** a `Destination` case (e.g. `.seedHandoff(SeedHandoffPresentation)`) hosted in
  **`TripDetailPresentationHost`**. That's the standing rule in `docs/KNOWN-ISSUES.md`: never the
  outer view.
- **The sheet:** Copy Brief / Paste Result, the same door as `RecommendationHandoffSheet`. Reuse its
  pieces rather than forking them. Routing and the marker follow the existing paste path, with
  warn-not-block per Amendment 1.
- **The review** (`SeedReviewSheet`, ADR-0048 D7):
  - Sections: *Trip shape*, *Stays*, *Shortlist*, *Considering* (rings shown as "Choose one"),
    *Ruled out* (declined + deferred), *Already on trip*, *Notes* (`warnings`, ignored groups).
  - Each row: include toggle, editable verdict (re-derives the row), title, a note excerpt, booking
    badge, and `day_ref` as caption.
  - One **Import** button with the included count.
  - Errors from decode or commit go in an alert, and nothing is written.
- **The feature model stays thin:** selection, toggles, and presentation via its own `Destination`.
  Mapping, eligibility and commit live in `SeedPlan`.

## Tests

- Copy `docs/fixtures/seed-denmark.txt` to `GalavantLibrary/Tests/GalavantSchemaTests/Fixtures/`.
- **Decode, then plan, then commit on an empty trip** must produce ADR-0048 Appendix B's table:
  - 3 stays with spans 1–4, 4–7, 7–13, all `.toBook`;
  - 4 `.shortlisted`: Svanninge Bakker, ferry, Møns Klint, ND122;
  - 12 `.considering`;
  - 21 `.declined` (16 with the `Deferred —` prefix);
  - exactly 2 rings: "South Funen outside dinner", "Møn third dinner";
  - "Dragsholm meal" and "South Funen walk" reported as ignored;
  - `.toBook` on the ferry, ND122 and the six considering rows with `book_ahead`, and on **no**
    declined row;
  - length 13, year 2027;
  - one `.seed` document whose body equals the narrative.
- **Re-seeding** the same fixture marks every row Already on trip and writes nothing new.
- **Edge cases:** missing `GV-SEED`; malformed JSON; empty seed; summary fallback; unrecognized
  verdict; dropped invalid base reported; numeric `day_ref`; kind synonyms; `tooLarge` rolls back
  the whole import; v1 candidate paste still works.

## Done when

- One PR on branch `effort/adr-0048-slice-2`. `scripts/check-drift.sh` green, plus headless
  `GalavantTests` (`docs/verification.md`).
- No schema or migration change. If one seems necessary, stop and ask (`question-for-architect`).
- The completing PR:
  - adds a DONE-LOG entry;
  - marks this brief Done in `docs/efforts/README.md`;
  - sets `docs/NEXT_UP.md` to exactly this block:

    ```
    # Next Up — ADR-0048 Slice 3: seed matching (saved ideas, then the map)

    **Slices:** effort `adr-0048-slice-3` (one PR, branch `effort/adr-0048-slice-3`)
    **Briefs:** `docs/efforts/adr-0048-slice-3-seed-matching.md`
    **Done when:** per the brief's "Done when"; verification per `docs/verification.md`.
    **Owed:** Jon's device pass in `docs/device-passes.md` (not executor work).
    **Notes:** Matching runs inside the seed review before commit; the human's tap still selects.
    No new ingestion path: resolution goes through `RecommendationResolution.confirm`. No schema
    change. Start from a fresh `main`.
    ```

  - adds to `docs/device-passes.md`:
    - *re-copy the project instructions (now v2) into the ChatGPT project;*
    - *on a trip, Seed from Conversation → paste the brief into the Denmark conversation → paste the
      reply back → review → Import; check the founding document, stays, rings and Ruled out on
      iPhone and iPad.*
