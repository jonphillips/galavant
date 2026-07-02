# ADR-0030: Itinerary-aware suggestions — context-scoped discovery with one-tap pull+schedule

*Status: proposed — 2026-07-02. Extends ADR-0017 (context-aware chat) and ADR-0018
(discovery pipeline). Depends on ADR-0018's web-search wire + resolve/dedup stack, and —
for quality — ADR-0029's structured hours. The synthesis slice of M6e; sequenced last.*

## Context

ADR-0018 discovery is **context-free pool-stocking** — "2★ Michelin in the Loire" → a
list of candidates on the map, no trip in view. A **second, distinct** discovery mode
surfaced in the 2026-07-02 design chat: **itinerary-aware suggestion** — *"what could we
do Tuesday?"* — where the model knows the trip, the target day, its region, what's already
scheduled, and the taste profile, and proposes **structured stops you can add with one
tap.**

This is not new discovery infrastructure. It's **ADR-0017's context-aware chat leveled
up**: the chat/inspector already carries the trip + itinerary as `ChatContext`. What's new
is (a) a richer **per-day context payload**, (b) reusing **ADR-0018's discovery engine**
scoped by that context, and (c) a **structured suggestion surface** with a **one-tap
pull+schedule** affordance.

**The boundary question (ADR-0004).** "One-click add to itinerary" *sounds* like AI
routing the trip. Jon confirmed (2026-07-02) the reading that keeps it clean: **the tap is
the human's explicit pull+schedule; AI only proposes a fully-formed stop.** Nothing
auto-adds; a suggestion becomes a candidate `Idea` and the *same tap* pulls and places it.
AI helps the **mechanical** parts of scheduling; the taste/route decision **is** the tap.
This is the same "the model finds and structures; it never writes" line ADR-0018 draws —
here applied to a trip-scoped surface.

## Decision

### 1. The per-day context payload (GalavantChat)

Extend `ChatContext` with a focused **day lens**: the trip (name, certainty, start if
dated), the **target day number** + its derived weekday/date, that day's **region(s)**
(per-day region / the trip's `TripRegion` lens), the **already-scheduled stops** on that
day (kinds + locations, so suggestions fill gaps not duplicate), nearby stops on adjacent
days, and the shared + per-planner **taste profile** (ADR-0015 `TravelProfile`). This is
the "smart enough to know where we are and what's already on the schedule" substrate.

### 2. Engine — reuse ADR-0018 discovery, scoped + biased

The **same grounded discovery call** as ADR-0018, with the query composed from the day
context: region + schedule gap + kinds not yet covered + taste, and — once ADR-0029 lands
— **filtered to places open that weekday.** Results resolve through `PlaceMatcher` and
dedup against the pool via `DiscoveryDedup` exactly as ADR-0018, so a suggestion already
in the pool surfaces as **"already saved"** rather than being re-created.

### 3. Surface — structured suggestion cards, not prose

The model returns **structured suggestions** (`name`, `kind`, `locality`, `note`,
`whyItFits`, `sourceURL`) rendered as **cards** in the Trip screen's `.inspector` panel
(already there, ADR-0017), each with a **one-tap Add**. Conversational prose stays; the
*actionable* output is structured. (Also usable as free chat: "what's near Tivoli we
haven't scheduled?")

### 4. One-tap pull+schedule — a pure app action, not a model write

The **generation** is a grounded `complete()` (ADR-0018-style batch fetch; **the model
never writes**). The **commit** is a pure app action bound to the card's Add button,
composing the existing tested ops:

```
createIdea (candidate) ∘ pull onto this trip ∘ scheduleStop on the target day
```

Guardrails that keep it ADR-0004-clean:

- **It never fires without the tap.** The model proposes; the button commits.
- **Every scheduled stop traces to a real pool `Idea`** — Add creates a candidate first,
  then pulls+places it (ADR-0013), so the pool stays the single source and **undo is the
  normal unschedule/remove.**
- **Day-relative placement** (`Schedule.day(n)` or a daypart), never a pinned date — it
  slides with the trip like any planned stop (`trip-time-model.md` §2).

These ops are *also* the `findPlaces` / `createIdea` / `scheduleStop` **App-Intent verb
vocabulary** (the BACKLOG "composable substrate" payoff) — but exposing them to Siri /
a client-side tool-use loop is a **later** slice. In *this* UI the button calls the tested
ops directly; the model does not invoke the write.

### 5. UI placement

Lives in the Trip screen's chat/inspector (ADR-0017), scoped to the **focused day** (tie
to the `DayChipBar` / `focusedDay` lens the canvas already tracks). A day-header
affordance ("Suggest for Tuesday") seeds the query; suggestions appear as cards; **Add**
places the stop and it flows into the itinerary live via `@FetchAll`.

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **Let the model call `scheduleStop` as a tool** (client tool-use loop writes the itinerary) | Rejected for v1. Keeps AI on the never-writes side of ADR-0004/0018 — the **tap** is the write. The tool wrappers exist for the later Siri/composability path; the model doesn't auto-schedule. |
| **A brand-new discovery pipeline for the day case** | Rejected. It's ADR-0018's engine + ADR-0017's context — reuse, don't fork. |
| **Suggestions land directly as itinerary stops** (skip the candidate/pool) | Rejected. Every stop traces to a pool `Idea` (ADR-0013), so Add = createIdea ∘ pull ∘ schedule — pool stays the single source, undo is trivial. |
| **Prose suggestions only** | Rejected. Structured cards are what make one-tap add possible — the whole point. |
| **On-device generation** | Rejected for discovery (needs web search → frontier/BYO-key, ADR-0018/0014). On-device is fine for context summarization if ever wanted. |
| **Context-scoped grounded `complete()` → structured cards → one-tap app-side pull+schedule (chosen)** | Reuses the discovery engine + chat context, keeps AI proposing-never-writing, and makes the one-tap add a tested pure composition. |

## Relationship to prior decisions

- **ADR-0017 (context-aware chat):** extends the chat/inspector with a per-day suggestion
  context + actionable cards.
- **ADR-0018 (discovery):** reuses the grounded call + `PlaceMatcher` / `DiscoveryDedup`;
  this is the **trip-scoped sibling** of context-free pool-stocking. The model never
  writes.
- **ADR-0004 / ADR-0013 (explicit pull / candidate-vs-pulled):** the **tap** is the pull;
  suggestions become candidates, then the user pulls+schedules. AI proposes, never routes.
- **ADR-0029 (structured weekday hours):** lets suggestions be filtered to "open that
  day" — a quality input; degrade gracefully before it lands.
- **ADR-0015 (taste profile):** `TravelProfile` feeds the suggestion context.
- **ADR-0014 seam / [[galavant-ai-cross-app-seam]]:** `web_search` stays in
  `AnthropicWire` (GalavantAI, portable); the day-context assembly, suggestion decode, and
  createIdea ∘ pull ∘ schedule stay domain-side (GalavantChat / GalavantPlaces).
  Generic-in / domain-decoded-out.

## Consequences

- **GalavantChat:** a per-day `SuggestionContext` (extends `ChatContext`); a
  `PlaceSuggestionClient` (grounded `complete()` + structured decode) — or reuse ADR-0018's
  `PlaceDiscoveryClient` with the day query; the commit action composing
  createIdea ∘ pull ∘ `scheduleStop` over tested `TripIdea` / pool ops.
- **GalavantAI:** nothing new beyond ADR-0018's `web_search` wire (shared).
- **App:** suggestion cards in the Trip inspector; a "Suggest for <day>" entry tied to
  `focusedDay`; **Add** → pull+schedule → live itinerary.
- **Sequenced last of the three M6e threads** — the synthesis. Depends on ADR-0018 slice-0
  discovery quality; best with ADR-0029 hours in place.

## Slices

- **Slice 0 — piggyback the ADR-0018 spike:** once discovery quality holds, confirm a
  day-scoped query ("open Tuesday near <day-region>, not already scheduled") returns useful
  suggestions.
- **Slice 1 — context + generation:** `SuggestionContext` (per-day payload) +
  `PlaceSuggestionClient` (grounded `complete()` + structured decode); stub-backend tests.
- **Slice 2 — the commit action:** createIdea ∘ pull ∘ `scheduleStop` over tested ops;
  in-memory DB tests.
- **Slice 3 — the UI:** suggestion cards in the Trip inspector + "Suggest for <day>";
  `swiftui-specialist` checkpoint.
- **Slice 4 — docs:** flip to accepted; ROADMAP / BACKLOG / `docs/M6-EXECUTION.md`.
