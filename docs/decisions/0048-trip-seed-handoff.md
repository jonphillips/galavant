# ADR-0048: Trip seed handoff — one crossing from an open-ended Chat conversation into a Galavant trip

*Status: **proposed** — 2026-10-04 (drafted by the architect from a design conversation with Jon;
Jon accepted the two defaults below: the seed lands on a trip created first, and deferred places
go to the pool only). Origin: two documents ChatGPT produced for a real trip after an unformatted
"getting my bearings" conversation (a research dossier and a current-plan summary for Denmark).
A new **verb** on the ADR-0036 recommendation handoff. Rides ADR-0004 (explicit pull), ADR-0007
(single FK), ADR-0010 (freeform stops), ADR-0011 (stays), ADR-0012 + the trip sketch (per-day
regions), ADR-0015 (`IdeaEvaluation`), ADR-0019 (capture dedup), ADR-0035 (alternatives rings),
ADR-0037 (evaluation workspace), ADR-0047 (booking status). Adds one `TripIdeaStatus` case and
one synced table, so it is a schema/sync decision Jon ratifies.*

> **Vocabulary.** **Bearings** is the open-ended Chat conversation that decides a trip's shape
> before Galavant is involved: which regions, in what order, for how many nights, and why. The
> **seed** is the single handoff that carries that conversation's outcome into a Galavant trip.
> The **seed return** is what Chat sends back: a free-text **narrative** plus one JSON object.
> The **founding document** is that narrative, kept word for word on the trip. A **verdict** is
> the conversation's decision about a place: `core`, `considering`, `declined`, or `deferred`.

## Context

ADR-0036 assumes the conversation starts in Galavant: a trip, day, or stay exists, a brief goes
out, candidate places come back. That is the right model once a trip has a shape. It isn't how
trips start. Jon's actual workflow has three phases:

1. **Bearings, in Chat.** "Should we go north or south? Which bases? Three plus three, or two
   plus two plus two?" There is a lot of open-ended back-and-forth before anything is worth
   structuring. This stays in Chat, and that is correct: it is the flat-rate, many-turn reasoning
   ADR-0036's economic thesis says to spend the subscription on.
2. **The crossing.** Once the shape settles, the result has to get into Galavant. **Nothing
   handles this today.**
3. **Galavant-originated handoffs.** After the crossing, Galavant holds the plan and Jon starts
   further conversations from it (ADR-0036 as built).

The Denmark documents show what a bearings conversation produces when nobody asks for a format.
It is **not a candidate list.** Almost every place in it already has a verdict, and most of the
text is reasoning:

- a **taste statement** ("what we are optimizing for");
- a **trip shape**: 6 rural nights as Falsled 3 + Møn 3, then 6 nights in Copenhagen;
- **choose-one dining slots** ("one outside dinner: Norðdisk or Vester Skerninge Kro");
- **daytime ideas** for each base;
- **places ruled out, with reasons**, and an explicit instruction not to reopen them "without new
  evidence";
- **places deferred** to a named future trip ("Germany → Henne → Skagen → Gothenburg");
- **facts about places** that hold on any trip ("prefer the larger rooms with private bath");
- **things to book and to recheck** (the ferry, room categories, 2027 opening days);
- **reasoning that belongs to no single place** ("why 3+3 beats 2+2+2").

Galavant can already represent most of this (see the appendix). Three things are missing: a way to
**cross** in one step, a place to record **"considered and declined, here's why"** (ADR-0037 D6
dismiss deletes the row, and the reason with it), and a home for the **reasoning that fits no
record**.

Running ~27 already-decided places through the ADR-0037 one-at-a-time inbox would make Jon
re-triage decisions he has already made. The crossing needs a **bulk** review.

## Decision

**Add a `seedTrip` verb to the ADR-0036 handoff. The seed starts from a Galavant trip and is pasted
into the existing bearings conversation. Chat returns a narrative plus one JSON object. The
narrative is kept word for word as the trip's founding document. The JSON maps onto records that
already exist, plus one new status, `.declined`. A single bulk review, which matches places against
saved ideas before searching the map, commits it all in one human tap.**

### D1 — The seed starts from a trip, and is pasted into the bearings conversation

Jon creates the trip in Galavant first (usually a someday trip; one extra tap), then taps **Seed
from conversation**. That makes a normal handoff session: `sourceType: "trip"`, `scopeKey: nil`,
`taskType: "seedTrip"`. The brief is pasted into the **existing** bearings thread, which already
has all the context, so the brief does not need to restate it.

This keeps the token, contract marker, and session machinery from ADR-0036 and LLMHandoffKit
unchanged. There is no tokenless import door to design.

**One habit change, written down so it isn't rediscovered:** start bearings conversations inside the
ChatGPT/Claude project that holds the Galavant contract instructions (ADR-0036 D5), so the thread
already knows the return format when the seed brief arrives. If a thread started elsewhere, paste the
contract from Settings into it first.

**The seed brief** carries: the token, the trip name, the trip's current shape if it has one (length,
stays, stops, in `stopSummary` form, so a re-seed doesn't duplicate what is already there), and the
ask. It does **not** include saved pool ideas. Duplicate detection happens in Galavant (D7), where it
is reliable, rather than by asking the model to cross-reference a list.

### D2 — The return has two parts: a narrative, then a `GV-SEED` line, then one JSON object

```
GV-HANDOFF: <token from the brief>
GV-CONTRACT: v2
<narrative: Markdown prose, any length>
GV-SEED
{ "trip": { … }, "bases": [ … ], "places": [ … ] }
```

- **The narrative is kept verbatim** as the trip's founding document (D6). This is how the
  semantic-fidelity rule (jon-platform `docs/ios/semantic-fidelity.md`) is met cheaply: the JSON
  extraction is **review-dependent**, and the full original text sits next to it, so nothing pasted
  is lost even where the JSON simplifies.
- **The split is on the last line that is exactly `GV-SEED`.** Everything before it, after the
  header lines are stripped, is narrative. The JSON object is sliced from what follows using the
  existing slicer pattern (`HoursExtractor` / `TripCandidate` decode, now for an object rather than an
  array).
- **What is loud and what isn't.** Routing token and contract marker follow ADR-0036 Amendment 1
  (warn and proceed; only a contract marker *newer* than the build stops). A missing `GV-SEED` line or
  a JSON object that fails to decode **stops the whole paste and writes nothing**, narrative
  included. Half a seed is worse than none.
- An empty narrative is allowed (no founding document is created). Empty `bases` and `places` together
  is an error (`emptySeed`), matching `TripCandidateDecodeError.emptyCandidates`.

### D3 — The seed JSON, v1

Every field is optional unless marked. A missing optional field never blocks the import (ADR-0036 D4);
unknown fields are ignored.

```jsonc
{
  "trip": {
    "length_days": 13,          // proposed Trip.lengthInDays
    "year": 2027,               // proposed Trip.targetYear
    "quarter": 3,               // proposed Trip.targetQuarter (1–4)
    "summary": "…"              // one line; shown in the review, not stored
  },
  "bases": [{                   // lodging, in order
    "name": "Falsled Kro",      // required
    "locality": "Millinge, Funen",
    "search_hint": "Falsled Kro",
    "region": "South Funen",    // matched by name to a MapRegion (D4); never created
    "check_in_day": 1,          // required
    "check_out_day": 4,         // required, > check_in_day
    "why": "…",                 // → TripStay.inlineNote
    "place_notes": "…",         // → IdeaEvaluation (D4)
    "book_ahead": true          // → bookingStatus .toBook
  }],
  "places": [{                  // a TripCandidate (ADR-0036 D4) plus:
    "name": "Norðdisk",
    "locality": "Faaborg",
    "search_hint": "Norðdisk Faaborg",
    "kind": "food",
    "why": "…",                 // fit with THIS trip → TripIdea.inlineNote
    "verdict": "core",          // core | considering | declined | deferred
    "reason": "…",              // required for declined/deferred
    "future_trip": "…",         // deferred only: a label, e.g. "Northern Denmark"
    "place_notes": "…",         // true of the place on any trip → IdeaEvaluation
    "group": "funen-dinner-2",  // places sharing a group are a choose-one ring
    "day_ref": "4",             // advisory only, shown in the review (ADR-0036 D6)
    "book_ahead": true
  }]
}
```

The contract clause that goes into the project instructions is in the appendix, so Jon can test it
by hand before any code exists (Slice 0).

**Separating `why` from `place_notes` is the key instruction to the model.** "Norðdisk is the lighter
second dinner after Falsled" is about *this trip*. "Rooms at Ellevilde vary; ask for a larger one with
private bath" is true of *the place* on any trip. ADR-0036 D3 already put trip-specific reasoning on
`TripIdea` so it can't leak into other trips; facts about the place need to go where every future trip
can see them.

### D4 — Every part of the JSON maps onto an existing record

| Seed JSON | Becomes | Notes |
| --- | --- | --- |
| `trip.length_days` / `year` / `quarter` | Proposed edits to `Trip` | A review row showing old → new values. Default on only when the trip still has the new-trip defaults |
| `bases[]` | `TripStay` with `checkInDay`/`checkOutDay` | Freeform (`inlineTitle`) until resolved; `ideaID` is set on resolution (D7). Creating it is allowed under the "new records carry no identity" exception (ADR-0036 D6; yes-chef `workbenchDraft`) |
| `bases[].region` | `TripDayRegion` rows for the stay's nights | **Only** when the name matches a MapRegion already attached to the trip, or else exactly one MapRegion in the party. Otherwise nights stay unassigned: the trip sketch's Q1 rule (regions are made on the Ideas map, never inline) holds. OQ2 |
| `bases[].book_ahead`, `places[].book_ahead` | `bookingStatus: .toBook` | ADR-0047's explicit value |
| `verdict: core` | `TripIdea` `.shortlisted` | Unscheduled. `day_ref` is shown as a hint, not applied |
| `verdict: considering` | `TripIdea` `.considering` | |
| `verdict: declined` | `TripIdea` `.declined` (D5) | `reason` goes in `inlineNote` |
| `verdict: deferred` | `TripIdea` `.declined` (D5) | `inlineNote` = "Deferred — *future_trip*: *reason*". Reaches the pool on resolution (D5) |
| unknown verdict | `.considering` | The review row shows the original verdict text, so the downgrade is visible |
| `why` | `TripIdea.inlineNote` / `TripStay.inlineNote` | Joined to `reason` when both are present |
| `place_notes` | `IdeaEvaluation` on the resolved `Idea` | `sourceName: "Trip research"`, `kind: .text`, `confidence: .inferred`, `staleness: .current`, `evaluationDate` = import date, `summary` = the text. If the row is unresolved at commit, the text is appended to `inlineNote` under an "About the place:" line instead. Nothing is dropped |
| `group` | `alternativeGroupID` ring (ADR-0035) | Members share one new UUID; at least two members, otherwise the group is ignored and the review notes it |

No `open_questions` or "things to recheck" field. Those are prose, they stay in the founding document,
and anything bookable is already covered by `book_ahead`. Taste-profile suggestions are deferred (see
Slices).

### D5 — `.declined`: considered for this trip and ruled out, with the reason kept

Add `TripIdeaStatus.declined = 5` (raw values are never renumbered). It is a **pre-trip** end state.
It is different from `.skipped`, which is the post-trip "didn't do it" that feeds visited state back to
the pool.

- **Not trip membership.** `.declined` rows stay off the shortlist, the itinerary, the booking rollup,
  and every pull surface. They appear in a collapsed **Ruled out** section on the trip, each with its
  reason. Changing the status back to `.considering` restores one; nothing is lost.
- **They stop re-suggestions.** ADR-0030 in-app suggestions exclude ideas declined on the same trip.
  Every outbound handoff brief for the trip adds an `Already ruled out:` list (name — reason), so Chat
  is told the conclusion and not asked to argue it again. This is the doc's "don't reopen old questions
  without new evidence" turned into a mechanism.
- **"Deferred" is a declined row with a different reason.** There is no separate status: for this
  trip, deferred and declined behave identically. What makes deferred places useful later is the
  **pool**. Resolving a declined row (D7) mints or links its pool `Idea` through the capture merge, so
  Skagen, Ruths, and Henne appear on the Ideas map for any future trip in that region. That is
  PRODUCT.md's canonical case. Routing deferred places onto a second someday trip is deferred (Jon's
  default).
- **Not visited.** `.declined` says nothing about having been there and does not feed visited state.
- **ADR-0037 D6 is unchanged for now.** Dismiss in the evaluation workspace still deletes. Whether the
  workspace should also offer "Decline with reason" is OQ4.

### D6 — The founding document: a `TripDocument` table, read-only in v1

```swift
@Table public struct TripDocument: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var tripID: Trip.ID          // the one real FK (ADR-0007); cascades with the trip
  public var title: String            // "Founding conversation — 4 Oct 2026", editable
  public var body: String             // Markdown, verbatim
  public var origin: TripDocumentOrigin   // .seed | .pasted (Int raw values, never renumbered)
  public var createdAt: Date
}
```

- **Synced**, because both planners need it and it must be readable offline on the trip. It goes
  through `SyncEngine` registration and CloudKit production schema promotion like every synced table.
- **Several per trip, append-only from the seed.** A re-seed creates a new document and never
  overwrites one, so there is a history of how the plan changed.
- **"Add document" (paste) is in scope.** It is the same table with `origin: .pasted`, and it covers
  material from before this ADR, such as the existing Denmark files, without needing a seed.
- **Read-only display in v1.** Rename and delete are allowed; body editing is not. The founding
  document is a record of the conversation, not a notes field. `Trip.notes` remains the user's own
  space (ADR-0026's line between source text and the user's text).
- **Size.** Bodies of a few tens of KB are expected. Reject a body over 500 KB loudly, well under
  CloudKit's 1 MB record limit, rather than letting the sync fail silently.
- **How Markdown with headings and tables is rendered** is OQ1.

### D7 — One bulk review that checks saved ideas first, then the map

This **deliberately departs from ADR-0036 D4's one-tap-per-row review.** The verdicts were made by the
two of us in the conversation, so re-deciding each one would be busywork. The human's single tap on a
reviewed sheet is still the only write (ADR-0004).

**The sheet**, top to bottom: *Trip shape* (proposed `Trip` edits, the region days) → *Bases* →
*Places* grouped by verdict, with groups shown as rings → *Ruled out*. Each row starts set to its
verdict and has an include toggle and an editable verdict. One **Import** tap commits every included
row in **one transaction**.

**Matching runs inside the review, before the commit,** so the results are part of what the human
reviews:

1. **Saved ideas first.** Normalized name (plus locality when given) against the party's pool `Idea`s,
   reusing `RecommendationCandidateIdentity.normalized` and logical uniqueness (ADR-0008/0019). A hit
   shows **"Saved idea"**. This is the "Chat suggests something I already have" case.
2. **Then the map.** A region-biased `MKLocalSearch` from `search_hint` + `locality` through the
   capture matcher (ADR-0016; bias, not fence, per ADR-0045). Exactly one confident result shows
   **"Map match"**. Searches run with limited concurrency through the injected client, since a seed can
   carry 30 places.
3. **Otherwise unresolved.** The row commits as freeform. Ambiguous rows show their choices inline;
   resolving them is optional.

**Confirm all obvious matches** is one tap that accepts every row with exactly one saved-idea or map
match. Confirming a match runs the existing capture confirm-merge (ADR-0019) at commit time. A row
still unresolved after commit belongs to the handoff session's candidate set, so the ADR-0037
workspace can open those rows later; no new workspace is needed.

**Re-seeding and duplicates.** A row matching a live `TripIdea` already on the trip (the existing
`RecommendationCandidateSet.liveTripIdea`), or a stay with the same title and nights, shows as
**Already on trip** and is excluded by default. A verdict change on such a row (for example, an
existing `.considering` row the seed says is `declined`) is offered as a status update, also off by
default.

**Pure core.** JSON → a `SeedPlan` value (the planned writes, with each row's match state) → the
commit is a pure, test-first mapping in GalavantSchema. The review's `@Observable` model only holds
selection, toggles, and the matcher's async state (watch for fat models).

### D8 — Contract v2

`RecommendationHandoffContract.projectInstructions` gains the seed clause (appendix), and the marker
moves to `GV-CONTRACT: v2`. Jon re-copies the instructions into the ChatGPT/Claude project once.
`candidatePlaces` returns stamped `v1` still parse, because an older marker warns and proceeds
(Amendment 1). The seed clause is written for the **app** (`RecommendationHandoffContract`), not
the shared kit. Verb text and payloads stay per-app (ADR-0036 §The lift).

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **Enter the trip by hand** | Viable once, but this happens for every trip, and each time ~30 places and their reasoning get retyped. It also loses the reasoning that fits no record. |
| **Parse the Markdown files in-app with `ModelClient`** | Rejected. It pays metered tokens to re-derive what the conversation already knows, against ADR-0036's flat-rate thesis, and it extracts from a document instead of asking the conversation that wrote it. The pasted-brief path costs nothing extra. |
| **A tokenless "import research" door** (paste without a trip or session) | Rejected. It would duplicate routing, the contract check, and session bookkeeping for the sake of skipping one tap. Creating the trip first is cheap (Jon's default). |
| **Strict JSON only, no narrative** | Rejected. The reasoning that fits no record (why 3+3, the comparison table) would be lost, and the JSON simplification would have no original to check against. |
| **Narrative only, no JSON** (store the document; enter the structure by hand) | Rejected as the end state, though it is effectively Slice 1 (manual "Add document"). |
| **Seed through the ADR-0037 workspace** | Rejected as the main path: it processes untrusted candidates one at a time, while a seed is mostly decided verdicts. The workspace stays the place to resolve leftovers (D7). |
| **Keep `.considering` for declined places, or delete them** | Rejected. Deleting loses the reason (the thing the documents were written to keep), and leaving them in `.considering` clutters the live list and invites re-suggestion. |
| **Separate `.deferred` status** | Rejected. For this trip it behaves exactly like `.declined`. The future value is in the pool, which resolution already provides. |
| **Route deferred places onto a second someday trip** | Deferred (Jon's default). A handoff that writes into a trip other than its source is new territory. Pool-only first. |
| **Create MapRegions from base names** | Deferred to OQ2. It conflicts with the trip sketch's sign-off that regions are made on the Ideas map. |
| **Learnings table** (ADR-0036 D7) **for the reasoning that fits no record** | Not yet. The founding document holds it losslessly, and a typed `Learning` home can come later if the reasoning turns out to need structure. |

## Relationship to prior decisions

- **ADR-0036:** a new verb on the same session, token, and contract machinery. D4's one-tap-per-row
  review is deliberately replaced by a bulk review **for this verb only** (D7). D6's identity rule holds:
  placement hints stay advisory, and the only things placed by day are new stays, which carry no
  identity.
- **ADR-0037:** unchanged. It resolves the seed's leftover unresolved rows. OQ4 asks whether it gains
  "Decline with reason".
- **ADR-0004:** the model proposes; the human's Import tap is the only write.
- **ADR-0012 / trip sketch:** bases write `TripDayRegion` rows only for regions that already exist.
- **ADR-0015:** `place_notes` become `.inferred` `IdeaEvaluation`s, with staleness, so "service was
  inconsistent in 2026" can age.
- **ADR-0019 / ADR-0008:** matching against saved ideas and the map reuses capture dedup and logical
  uniqueness; there is no new ingestion path.
- **ADR-0026:** the founding document is source text and stays out of `Trip.notes`.
- **ADR-0030:** suggestions exclude ideas declined on the same trip.
- **ADR-0035:** `group` → ring.
- **ADR-0047:** `book_ahead` → explicit `.toBook`.
- **Cross-app:** the two-part return is the "deliverable plus learnings" split yes-chef uses (ADR-0036
  D7), applied with a narrative instead of learnings. If yes-chef needs the same split, that is the
  point to lift a return-splitting helper into LLMHandoffKit (one more SEAM-LEDGER row; not designed
  here).

## Consequences

- **Schema:** `TripIdeaStatus.declined = 5`; new synced `TripDocument` table (migration, `SyncEngine`
  registration, CloudKit production schema promotion). **Owed device gate:** a document created on one
  device shows on the second after sync.
- **GalavantSchema (pure, test-first):** `SeedReturn` decode (narrative split, object slice,
  lossless-or-loud, fixture-tested); `SeedPlan` mapping (D4) and duplicate handling (D7); status
  semantics for `.declined` (`isOnTrip`, rollups, the suggestion filter, the brief's ruled-out list).
- **App:** the "Seed from conversation" entry on a trip; the seed review sheet; the Ruled out
  section; the document list and viewer; "Add document".
- **Contract:** `GV-CONTRACT: v2`, re-copied into the ChatGPT/Claude project once.
- **Public repo hygiene:** the test fixture leaves out dates and seasons, and Jon's original research
  files are **not** committed (this repository is public). The fixture keeps the structure, which is
  all a test needs.

## Slices

- **Slice 0 — hand-run the contract (Jon, no code).** Paste the appendix clause into the Denmark
  bearings conversation followed by "Seed this trip from our conversation." Check the return against
  [the fixture](../fixtures/seed-denmark.txt): did it separate `why` from `place_notes`, use verdicts,
  and form groups? Adjust the clause before Slice 2. This follows yes-chef's method and ADR-0036 OQ4.
- **Slice 1 — `.declined` and `TripDocument`.** Status case and its semantics; the Ruled out section;
  the document table, list, and read-only viewer; "Add document" (paste). Useful immediately: Jon can
  attach the existing Denmark files.
- **Slice 2 — the seed verb.** Contract v2, the seed brief, `SeedReturn` decode, `SeedPlan` mapping,
  the bulk review, and a one-transaction commit with **every row freeform** (no matching yet).
  Fixture-tested end to end.
- **Slice 3 — matching.** Saved ideas, then the map; "Confirm all obvious matches"; `place_notes` →
  `IdeaEvaluation` on resolution; unresolved rows openable in the ADR-0037 workspace.
- **Deferred (designed, not built):** taste-profile suggestions from the seed (shown as a diff against
  `TravelProfile`, applied by tapping); routing deferred places onto a someday trip; founding
  documents as chat context (OQ3).

## Open questions

- **OQ1 — Rendering the Markdown.** The documents use headings, lists, and tables. Options:
  `AttributedString(markdown:)` with full syntax plus a small block renderer of our own; a Markdown
  rendering package (a new dependency, which needs a reason); or Markdown → HTML in the existing
  `WebView`. A minimal acceptable start is plain text with inline styling. Assess at Slice 1.
- **OQ2 — Regions for bases.** If a base's `region` matches no MapRegion, should the review offer to
  create one centred on the resolved base, at a default zoom? That would loosen the trip sketch's
  "regions are made on the Ideas map" rule. Decide after dogfooding.
- **OQ3 — Documents as context.** Should founding documents feed in-app chat (ADR-0017) and outbound
  briefs? It is probably valuable, but briefs grow, and the bearings conversation already has the
  context. Later.
- **OQ4 — Decline in the evaluation workspace.** Should ADR-0037 offer "Decline with reason" alongside
  delete-on-dismiss, now that `.declined` exists?

## Appendix A — the seed clause for the project instructions (draft; Slice 0 tests it)

```
When asked to seed a Galavant trip, summarize our conversation so far as a Galavant seed.
Reply with: the GV-HANDOFF line from the brief, then "GV-CONTRACT: v2", then a narrative,
then a line containing only "GV-SEED", then one JSON object. Do not wrap the JSON in Markdown.

The narrative is Markdown for us to reread later: the trip's shape and the reasoning behind
it, comparisons, open questions, things to recheck before booking. Keep it complete; it is
stored as written.

The JSON object has three keys:
- "trip": length_days (number of days, counting arrival and departure days), year, quarter (1-4).
- "bases": lodging in order. name, locality, search_hint, region (the area's common name),
  check_in_day, check_out_day (day numbers, day 1 = first day), why, place_notes, book_ahead.
- "places": everything else we discussed, including places we ruled out. name, locality,
  search_hint (an Apple Maps query), kind (sight, food, drink, stay, tour, activity, beach, park,
  outdoorTrail, museum, theater, nightlife, shop, market, transit), why, verdict, reason,
  future_trip, place_notes, group, day_ref, book_ahead.

verdict is "core" (we plan to do it), "considering" (undecided), "declined" (ruled out for this
trip), or "deferred" (saved for a future trip; name it in future_trip). Give a reason for
declined and deferred.

Keep two kinds of notes apart: "why" is about how the place fits THIS trip; "place_notes" are
facts or advice true on any visit (which rooms to ask for, how long a meal runs, opening quirks).

Places that are alternatives for the same slot ("Norðdisk or Vester Skerninge Kro") share the
same "group" string. book_ahead is true when it needs a reservation or ticket in advance.
Include only places we actually discussed. Omit a field rather than guess.
```

## Appendix B — the Denmark conversation, mapped

[`docs/fixtures/seed-denmark.txt`](../fixtures/seed-denmark.txt) is the Denmark bearings outcome,
hand-converted into a v2 seed return. It shows the contract can carry a real conversation, and it is
the test fixture for Slices 2–3. Leaving dates out is deliberate (Consequences). What it becomes:

| From the conversation | In Galavant |
| --- | --- |
| 6 rural + 6 Copenhagen nights | Trip length 13 days, year 2027 |
| Falsled Kro, nights 1–3; Ellevilde, nights 4–6; Copenhagen hotel, nights 7–12 | Three `TripStay`s; the Copenhagen one freeform ("Copenhagen hotel — to choose"), all `.toBook` |
| Norðdisk **or** Vester Skerninge Kro; Egn **or** Bryghuset Møn | Two choose-one rings |
| Svanninge Bakker, Faaborg, Møns Klint, Camøno, Stege, Nyord, ND122, the ferry | `.shortlisted`; the ferry `.toBook` with day hint 4 |
| Dragsholm Slot Bistro lunch, a Dark Sky evening | `.considering` |
| Alsik, Frederiksminde, Dyvig Badehotel | `.declined` with reasons |
| Ruths, Okê, Råbjerg Mile, Henne Kirkeby Kro, Molskroen, Mols Bjerge | `.declined` "Deferred — Northern Denmark: …"; in the pool once resolved |
| "Prefer the larger private-bath rooms", "Okê runs very long", "2026 service reports mixed" | `IdeaEvaluation`s on the resolved places |
| Why 3+3; the candidate comparison table; the things to recheck | The founding document |
| "What we are optimizing for" | The founding document now; a `TravelProfile` suggestion once that is built (deferred) |
