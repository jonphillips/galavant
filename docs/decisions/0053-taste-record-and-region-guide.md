# ADR-0053: Galavant keeps the taste record, and a region guide is where it's read

*Status: **proposed** — 2026-11-04, ratified by Jon merging this ADR's PR. First effort:
[`taste-notes`](../efforts/archive/taste-notes.md). Adapts Vinyl Fever's `docs/taste-intelligence.md` to a shared, iOS-only
app. Builds on [ADR-0015](0015-source-evaluations-and-taste-profile.md) and
[ADR-0048](0048-trip-seed-handoff.md), and reads and stages through
[ADR-0052](0052-chat-access-over-mcp.md). Replaces [ADR-0018](0018-ai-pool-stocking-discovery.md) §3, which was never
accepted. Picks up [ADR-0036](0036-recommendation-handoff.md) D7 (learnings).*

*Amended 2026-11-08 after Jon's first use of the S3 guide: **D8** gives the guide an optional trip lens, and S3.1–S3.3
are added to the slices. Mockup: [`region-guide-trip-lens.html`](../mockups/region-guide-trip-lens.html).*

Summary: Galavant owns the evidence of what Jon and Wendy like and why, for restaurants, hotels, and anywhere else,
in their own words. The chat assistant does the interpreting. Recommendations are kept as answers to a question, next
to what actually happened. A region guide over `Idea` becomes the place to browse and read all of this, without a Dining
domain, a Dining tab, or a stored score.

> **Vocabulary.** A **taste note** is a dated statement in a person's own words, about a place or about travel in
> general. A **recommendation record** is what a chat recommended, for what question, and why. The **region guide** is
> a view over a region and a category. The **universe** is an external list of noteworthy places in a region, such as
> a Michelin selection. A **dossier** is the read-first presentation of one place.

## Context

Galavant began as a geographic collection of interesting places, and PRODUCT.md describes it as a planning loop: collect,
pull, schedule. Browsing, judging, and remembering places are satisfying in their own right, and the app gives them little
room. Tapping an idea in Ideas opens the editor. There's no reading surface in the pool at all: `IdeaDetailView` is only
reachable from Trip and Today.

The most useful judgment already happens elsewhere. Jon asks ChatGPT to predict what he'd like, and those conversations
reach real conclusions: why a hotel failed, which warning signs to look for next time, which restaurant suits a particular
lunch. Those conclusions live in ChatGPT's history and memory. Jon can't inspect them, correct them, share them with Wendy,
or carry them to another assistant.

A real recommendation conversation showed what the record has to respect:

- **A verdict answers a question.** The question was a specific lunch, with its days, dress code, and format. A flat
  "good fit for Jon" label on each restaurant would lose that.
- **Why something was ruled out matters.** One highly regarded restaurant was excluded only because its lunch days didn't
  fit. Stored as "not recommended", that would mislead for years.
- **Most of the text expires, and a little of it lasts.** Prices, opening days, and offers go stale. A sentence about the
  flavors and rooms that suit him doesn't.

Vinyl Fever already solved the general problem: it keeps evidence, the chat interprets it, and neither scores nor a stored
model-written profile are involved. Galavant differs in three ways:

- It has no passive signal. Music produces plays and playlist changes on its own, while a restaurant or hotel produces
  nothing unless someone records it. Notes are the evidence, so capture has to be easy and past experience has to be
  brought in.
- Volumes are too small for keep rates. A person eats at a few notable restaurants a year.
- Two people share the data, so it belongs in the synced travel-party tree, not in append-only files on one iCloud account.

## Decision

### D1 — A second loop: explore, keep, remember

Galavant gains a loop beside collect → pull → schedule. **Explore** what's noteworthy somewhere, **keep** what matters, and
**remember** what happened and why. Neither loop serves the other, and neither requires a trip. PRODUCT.md is amended to say
so.

**An `Idea` is now a place we hold an opinion about,** not only one we want to visit. A hotel we hated is a legitimate kept
Idea with `doNotDo` interest. Browsing surfaces will hide `doNotDo` places by default, and that lands with the guide (S3).

### D2 — Taste notes: verbatim, synced, and not tied to any category

- **A note is someone's words,** never a model's interpretation stored as fact. A model may propose a note, but only a
  person's tap saves it, and it can be reworded first. This holds ADR-0004's spine and Vinyl Fever's rule: "Never store an
  interpretation as a fact."
- **No category.** Notes work for restaurants, hotels, and anything else from the first build. A note can be about a saved
  Idea, about a place that was never saved, or about no place at all ("long formal meals wear me out"). We add no category
  field until the list is too long to send whole.
- **A note outlives its trip and its Idea.** It never hangs off a `TripStay` or `TripIdea`, because those are deleted with
  their trip and a stay may have no Idea. Each note keeps the place's name in text, so deleting an Idea doesn't lose the
  opinion. This is a deliberate difference from `IdeaEvaluation`, which orphan-drops on read.
- **It isn't an `IdeaEvaluation`.** An evaluation is one source's judgment of one place, and it can't hold a general note.
- **It isn't `TravelProfile`.** The profile stays a short, hand-kept summary, overwritten when it changes. Notes are dated
  evidence that accumulates.
- **Heuristics stay as words.** A warning sign someone works out in conversation is a note. Galavant doesn't compute it,
  fetch data for it, or turn it into a rule; the chat applies it when it reads the note.
- **Both people's notes are shared** (ADR-0003). Who said it is a subject, not access control, as with `IdeaInterest`.

### D3 — The chat interprets, and Galavant keeps the evidence

- **No scores, no fit numbers, no ratings on notes, and no stored model-written taste profile.** Synthesis happens fresh in
  each conversation.
- **Recommendations argue from named examples,** so briefs and project instructions ask for that.
- **Notes go only to named readers** (ADR-0015's amendment): outbound briefs, in-app chat, and ADR-0052's `get_trip`. Each
  reader renders them through one Core function, and when a cap leaves notes out, the text says how many.
- **ChatGPT stays the place to deliberate.** Galavant isn't rebuilding its judgment, only making sure that what it learns
  doesn't stay there.

### D4 — Getting notes in, and getting them out to chat

- **Directly:** add a note from a place or from the notes list.
- **From past conversations:** a paste door takes a chat's list of proposed notes into a row-by-row review. This is how
  history already sitting in ChatGPT comes home. Conversation exports are the better source, because they hold what was
  said rather than the assistant's memory of it.
- **Paste works first, and MCP follows.** ADR-0052 is already approved and queued, so notes ride it once its read tools
  exist. A later slice adds trip-free tools on the Vinyl Fever model: reading notes, and staging proposed notes for the same
  review. A model never saves a note directly.

### D5 — A recommendation is kept as an answer, next to what happened

*Direction here; the design is S4's.*

- A recommendation record holds the question, the narrative verbatim, and for each place a stance and a reason. **The reason
  says whether the place was ruled out on taste or on logistics.** ADR-0048's `verdict` and `reason` are close to this.
- **Perishable facts stay in the narrative.** Prices, opening days, and dress codes never get written onto an `Idea` from a
  recommendation.
- **The dossier shows the prediction beside what happened.** We don't compute keep rates. There's too little data for them
  to mean anything, so the record is there to be read.
- **It can't require a trip.** `TripDocument` has a required `tripID`, so standalone browsing needs a different home or a
  loosened one. S4 decides which, and it's a synced-schema decision that comes back to Jon.
- **Trips still count.** Many of these conversations are about a real trip, and those should keep working through
  Summarize Conversation and chat access.

### D6 — The region guide is a view, and the universe isn't Ideas

- **One screen, scoped by region and category.** It's reached from Ideas. Dining is the first category, and hotels are the
  same screen with a different card and dossier emphasis, chosen by the existing `IdeaKindGroup`. There is **no Dining tab
  and no Restaurant entity** (ADR-0015). PRODUCT.md's line still holds: the map and filter view is the guide, and no Guide
  entity is saved.
- **It isn't the recommendation workspace.** That screen is an inbox worked down to zero, bound to a trip, and sized for a
  dozen candidates (ADR-0037). The guide reuses its parts (`PlaceSelectionMap`, capture merge, seed matching, browser with
  field capture), not the screen. **The dossier is primary** here because it holds what we already know, and the browser is
  a tap away.
- **Shortlists are filters.** *Want to Go* and *Not for Me* are `Interest` levels, and *Favorites* comes from notes. No new
  list entity (ADR-0004).
- **The universe stays out of the pool.** Seeing a guide's whole list creates no Ideas, and keeping a place is one deliberate
  tap through the capture merge. The list is external, regenerable, and **device-local to start**, because CloudKit schema
  deploys are permanent. It joins to Ideas when read.
- **This supersedes ADR-0018 §3 ("Add all", candidates as Ideas).** It also answers the M6 question of which discovery route
  to take: external conversation first, with `PlaceDiscoveryClient` parked.
- **We build it to learn how it feels.** The guide is hard to judge on paper, and it adds little that's permanent, so S3
  gets built and reviewed on a device before anything further is decided about it.

### D7 — `visited` stays a coarse flag

`Idea.visited` is shared across the party, it's meant for "not yet visited" trip planning, and the trip roll-up only reads
`TripIdea` stops, so hotel stays never set it. It can't carry dining or hotel history, and we won't stretch it to. History
lives in notes.

### D8 — The guide gains an optional trip lens (amended 2026-11-08)

Jon's first use of the guide found two gaps. Tapping into each place and back out again was tedious. And picking where to eat
meant remembering which of the trip's lunches and dinners were already filled. Adding to the busy Trip screen wasn't the
answer, and neither was a third view of the trip for deliberating. The guide gets a lens on the trip instead.

- **The dossier opens over the map, not in place of the list.** On iPad it's a panel floating over the map's trailing edge,
  and the list stays where it was. On iPhone it's a sheet over whatever is showing, at half height to start. Tapping another
  place swaps what's in it. This supersedes S2's column swap. Ideas gets the same presentation, because the two screens share
  one container.
- **The lens appears only when a trip has days in the guide's region** (`TripDayRegion`, ADR-0012). With no such trip, the
  guide is exactly what it was. It never requires a trip, so D1 holds.
- **Dining shows lunch and dinner slots** for those days. **Hotels shows the nights.** A slot shows whatever is in it, from
  wherever it came: a booked stop, an alternatives ring (ADR-0035), a freeform stop, or nothing.
- **The guide edits the same rows as the trip,** through the operations the Trip screen already uses. It can put a place in
  an open slot, add a place to a filled slot as another option, pick which option is active, or take one option back out. It
  keeps no state of its own about the trip. Considering several places for one slot *is* a ring, so there's no new
  "deliberation" entity.
- **No schema.** Hotels can be shown night by night, and an open night can take a stay. Keeping several *candidate* hotels for
  the same nights has nowhere to live, because rings exist only on `TripIdea` and a `TripStay` is one commitment. That's OQ5.
- **It's still not the recommendation workspace** (D6). That workspace is an inbox bound to one trip. The guide is reached
  without a trip, and it only shows a trip when the region has one.

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **Leave taste in ChatGPT's memory** | Rejected (Jon, 2026-11-04). It can't be inspected, corrected, shared, or moved to another assistant. |
| **Reflections as `.personal` `IdeaEvaluation`s** | Rejected, though it would avoid a schema deploy. It can't hold a general note, it needs an Idea, and it would disappear on read when that Idea is deleted. |
| **Extend `TravelProfile`** | Rejected. It's a short summary overwritten in place, with no dates or subjects. |
| **Separate tables for dining and hotel feedback** | Rejected. The mechanism and the reader are the same, and the distinction lives in the words. |
| **Structured ratings or questionnaires** | Rejected. They'd add a rating vocabulary (ADR-0015 already declined a third), and short natural reflections hold the reasons. |
| **Fit scores** | Rejected. Too little evidence, and false precision. Vinyl Fever made the same call with far more data. |
| **Append-only files in iCloud Drive, as Vinyl Fever does** | Rejected. Wendy shares this data, and a ubiquity container belongs to one account (ADR-0052 D2). |
| **Dining tab or Restaurant entity** | Rejected. Each new category would want its own, and ADR-0015 settled on one canonical `Idea`. |
| **Universe entries as Ideas** | Rejected. Saving is the pool's first filter, and a guide's full list isn't a statement of interest. |

## Consequences

- **Permanent CloudKit schema:** `taste-notes` adds one synced table, which can never be removed from Production. It's plain,
  additive text, so the risk is low, and this PR is Jon's approval of it.
- **`Idea` semantics widen** (D1), and `doNotDo` needs default filtering before the guide ships.
- **Chat costs:** notes make briefs longer, so they need a cap. On-device chat can't carry them all (see the brief).
- **ChatGPT's stored conclusions become a backfill job.** It's a human review, so it takes Jon's time, once.
- **Privacy:** this repo is public. Notes, conversations, and exports never go in it. Fixtures use invented places and words.

## Slices

1. **S1 — Taste notes** ([`taste-notes`](../efforts/archive/taste-notes.md)): the table, adding and browsing, the conversation import,
   and briefs and chat reading them.
2. **S2 — Dossier:** tapping an idea reads before it edits, with accolades, images, and notes.
3. **S3 — Region guide over kept Ideas:** cards, grouping, and default `doNotDo` filtering. A device review decides what
   happens next.
4. **S4 — Recommendation records:** the question, the narrative, stances with reasons, and prediction beside outcome.
5. **Gate, then S5 — the universe:** before any design, compare a chat's list for two regions against the guide's own, and try
   reading the guide's list pages through the in-app browser. The result decides how S5 is built, or whether it is.

The S3 device review added three slices before S4 (D8):

- **S3.1 — Dossier over the map** ([`guide-dossier-panel`](../efforts/archive/guide-dossier-panel.md)).
- **S3.2 — The trip lens, read-only** ([`guide-trip-lens`](../efforts/archive/guide-trip-lens.md)): meal slots and nights, with
  badges on the cards.
- **S3.3 — Filling slots from the guide** ([`guide-slot-filling`](../efforts/archive/guide-slot-filling.md)): Add to Trip, choosing
  among a slot's options, and Stay here for an open night.

S2 onward get briefs when they're next. Only S1 is dispatched by this PR.

## Open questions

- **OQ1 — `create_idea` from chat.** The in-app tool writes straight to the pool, which conflicts with deliberate promotion.
  M6 left this open. Settle it before chat sits inside the guide.
- **OQ2 — quick capture.** Vinyl Fever found the reason is the feedback that disappears, and solved it with a phone-first App
  Intent. Whether Galavant needs one depends on how notes actually get written.
- **OQ3 — when something happened.** A note has one date, when it was said. Whether the date of the visit deserves its own
  field can wait for real backfilled notes.
- **OQ4 — World's 50 Best.** It's a global ranking, so it can annotate a regional list but can't define one. Decide at S5.
- **OQ5 — Candidate hotels.** Comparing several hotels for the same nights, the way a ring compares lunches, needs
  somewhere to keep them, and that's a synced-schema decision. Decide after S3.3 has been used on a real trip.
