# ADR-0037: Recommendation evaluation workspace — a candidate set processed like an inbox, across three coordinated surfaces

*Status: accepted — ratified 2026-08-13 (Jon), M9. Origin: the same 2026-08-13 design
conversation as ADR-0036, after Jon pushed back on ADR-0036's original "no new screen" line. **Stacked on
ADR-0036** (the recommendation handoff), which owns the *substrate* — the device-local
handoff record, `.considering` `TripIdea` candidates, the strict-JSON return, the capture
merge — while this ADR owns the *surface* that processes a candidate set. Composes shared
components: the trip canvas / Ideas map (ADR-0013), the persistent browser + field-capture
bar (ADR-0025), the capture region-biased matcher and dedup (ADR-0016 / ADR-0019), the
alternatives ring (ADR-0035), and the row-grain review from ADR-0036. Holds ADR-0004's
explicit-pull invariant — the model proposes; the human's tap is the only write.*

> **Vocabulary.** A **candidate** is one fuzzy AI suggestion from a handoff return
> (ADR-0036) — a freeform `.considering` `TripIdea`. The **set** is all candidates from one
> handoff. **Resolution** is confirming a candidate against a real map place (**Use This
> Place**), which mints/links a pool `Idea` and harvests its facts. The **active candidate**
> is the one currently selected; there is always exactly one.

## Context

ADR-0036 lands a set of candidate places from an external-LLM round-trip and stops at the
row-grain review sheet — enough to *commit* candidates, not enough to *evaluate* them.
Evaluation is the real work, and it is a distinct, high-context job — not the same as
browsing the stocked pool on the Ideas shopping surface (ADR-0013), which is about pulling
from places you already trust. Here you are **processing an incoming batch of things you do
not yet trust**, and deciding each one needs two lenses held at once:

- **The map** — *does this make geographic sense?* Where is it relative to the day's
  itinerary and the lodging; is the AI's locality even right; which exact pin is it.
- **The browser** — *do I actually want it?* The website and its photos are what make a
  place obviously worth a half-day or obviously a tourist trap. This is where the decision
  is actually made, so it gets the most screen.

The set stays in view while you move through it — select, inspect geographically, research,
confirm the place, then Save to Ideas / Add to itinerary / dismiss, and on to the next. **It
is an inbox.** ADR-0036 proved this needs no new synced entity and no second ingestion path;
this ADR builds the screen over that substrate, composed from components that already exist.

## Decision

**Three coordinated surfaces — a candidate rail, a map, and a browser — with the browser
primary and exactly one candidate always selected. Selecting drives the map and browser;
confirming a map match (Use This Place) resolves the fuzzy suggestion into trustworthy
Galavant data while preserving the AI's trip intelligence; survivors graduate into Ideas or
the itinerary. Same candidate state on iPhone, presented sequentially.**

### D1 — Three coordinated surfaces; the browser is primary; one candidate is always selected

On iPad, three surfaces are visible together:

- **Candidate rail / cards** — the persistent control surface *and* the work queue: each
  card shows name, the AI **why**, fit, rough time commitment, **resolution status**, and
  the actions. Always on screen.
- **Map** — existing itinerary geography plus the set's candidates (D3).
- **Browser** — ordinary, unrestricted web browsing for the active candidate (ADR-0025),
  given the **largest share** of the stage, because the want/don't-want judgment is made
  here.

**The invariant is that exactly one candidate is selected at all times.** Selection is the
spine: tapping a card makes that candidate active, which highlights it on the map and points
the browser at it (D3/D5). There is no "nothing selected" state while a non-empty set is
open — the same discipline ADR-0035 used to kill its undecided state. This is what makes the
iPhone story a presentation change rather than a different feature (D7): the selection lives
in the feature model, not in navigation.

### D2 — The rail is the inbox; the processing loop is explicit

A candidate is processed along one path, and the rail makes progress legible:

```
select → inspect on map → research in browser → Use This Place → Save to Ideas / Add to itinerary / dismiss → next
```

Each candidate carries a visible **resolution status** (unresolved · resolved) and, once
acted on, leaves the queue (saved / added / dismissed). Progress **persists across sittings**
(D6): the set is the device-local handoff record (ADR-0036 D1), each candidate's state is
its `TripIdea` (`status` + whether `ideaID` is set), so you can resolve three, dismiss two,
leave five, and reopen tomorrow exactly where you left off. No new per-candidate state table.

### D3 — The map is three layers, and "highlight the map result" means different things before and after resolution

The map composes three distinct layers; conflating them is how this gets built wrong:

1. **Itinerary geography** — the day's/region's existing stops and lodging, for spatial
   context. Drawn as usual.
2. **The candidate's fuzzy marker** — before resolution there is no confirmed pin, only the
   AI's approximate `locality`. The active candidate's fuzzy marker is **emphasized**; the
   rest of the set is **muted** (reuse ADR-0035's muted/emphasized pin language).
3. **The resolve results** — transient `MKMapItem`s surfaced *only* during Use This Place
   (D4), the real places you choose from.

So "tap a candidate → its map result highlights" is layer 2 (the fuzzy marker) **before**
resolution and the confirmed pin **after**. Selecting a candidate never silently invents a
precise location; precision only arrives when the human confirms a real place.

### D4 — Use This Place: one region-biased gesture that fuses resolution and research

Confirming a candidate is a single gesture that reuses the capture pipeline rather than a new
matcher:

- **Auto-run a region-biased search.** From the candidate's `search_hint` + `locality`,
  biased by the trip/stay region, run the capture matcher's `MKLocalSearch` (ADR-0016) — so
  "Neustift Abbey" finds the South Tyrol one, not one in Austria, and usually offers **one
  obvious match**.
- **Confirm with Use This Place.** Tapping the correct `MKMapItem` runs the existing capture
  confirm-merge (ADR-0019): it mints or links a pool `Idea`, **dedupes onto an existing one**
  via `mapItemIdentifier` / logical-uniqueness if Galavant already knows the place, sets the
  candidate `TripIdea`'s `ideaID`, and harvests the reliable facts the provider exposes —
  canonical name, coordinates, address, category, website `url`, and identity.
- **Two dedup levels — pool `Idea` vs. intra-trip `TripIdea` — and only the first exists
  today.** The confirm-merge dedup above is at the **pool `Idea`** level: two candidates
  resolving to the same place link to one shared `Idea`. It does **not** reconcile the
  **`TripIdea` rows within a trip**. So the observed case (dogfooding 2026-08-14: "Louisiana
  Museum of Art" in **both** Shortlist and Considering) is expected under the current build,
  not a dedup bug: a `.considering` candidate carries no place identity (`ideaID == nil`,
  freeform `inlineTitle`) until resolved, so nothing keys it against an already-`.shortlisted`
  `TripIdea` for the same place. The system genuinely cannot know they're the same until the
  human resolves — resolution (Use This Place) is the **first moment** a candidate acquires the
  `ideaID` that makes the collision detectable, which is exactly where the reconcile belongs
  (OQ5), not a background convergence over unresolved prose.
- **Two-layer preservation is structural, not a feature.** The facts land on the shared
  `Idea` (cross-trip, dedup-keyed); the AI trip intelligence — *why this fits*, *pair with
  Brixen*, *cultural counterpoint* — stays on the trip-scoped `TripIdea` (ADR-0036 D3,
  rationale in `inlineNote`). Resolution sets `ideaID`; it never touches the rationale. So a
  resolved candidate carries **both** trustworthy place data and the reasoning that made it
  worth considering.
- **Ambiguity and no-match degrade gracefully.** Several matches → the human picks; none →
  the candidate stays unresolved and **still useful** (D6). Resolution is never forced (D6).

### D5 — The browser target is state-driven, and the AI never supplies it

The AI is not authoritative for URLs (ADR-0036), so the browser's destination is derived from
resolution state:

- **Before resolution** → a **web search from the `search_hint`** (find the site yourself).
- **After resolution** → the place's **`MKMapItem.url`**, the trustworthy official site.
- **Browsing can override** → if you find a better official URL while researching, the
  **field-capture bar (ADR-0025 §5) writes it back** — "Use this website for Neustift Abbey"
  — enriching the resolved `Idea`. This is the same capture bar pointed at a place instead of
  a fresh capture.

Selecting a candidate **auto-loads** its target (low friction is the point), loaded **lazily**
so skimming pure geography down the rail isn't heavyweight. The browser is otherwise a normal
persistent browser; navigating away does not change which candidate is active (selection is
model state, the URL is just where you are).

### D6 — Graduation: save without resolving, add as freeform, dismiss with undo

The survivors leave the queue three ways, and the rules reconcile "don't force resolution"
with ADR-0036's pool-cleanliness:

- **Save to Ideas — no resolution required.** This promotes the freeform `TripIdea` from
  `.considering` to `.shortlisted` (trip-scoped). It does **not** mint a pool `Idea` — only
  resolution does (D4) — so unvetted AI fuzz never enters the durable, dedup-keyed pool
  (ADR-0036 D3). An **unresolved shortlisted candidate is a valid state**; it simply renders
  with approximate/absent geography until resolved.
- **Add to itinerary — allowed unresolved, upgraded on resolution.** An unresolved candidate
  may be added as a **freeform stop** (ADR-0010); resolving it later **upgrades** it to a
  normal pulled stop. Jon's "lean toward resolving before it becomes a normal stop" is a
  **soft nudge in the UI, not a hard gate.** If the candidate carries a `placement_after`
  hint, that is an advisory suggestion the human confirms (ADR-0036 D6), never a silent slot
  write. A "choose one" group promotes as an **alternatives ring** (ADR-0035).
- **Dismiss — delete with undo.** Dismiss deletes the `.considering` `TripIdea` (with a
  standard undo), rather than adding a per-candidate "dismissed" status. Keeps the model
  clean and consistent with ADR-0036; a reopened set simply no longer lists it.

### D7 — iPhone: identical candidate state, sequential presentation

iPhone preserves **exactly the same candidate state and processing loop**, only the layout
sequences:

- **Home view** = map + candidate sheet (rail as a bottom sheet). Locating and **Use This
  Place happen here**, on the map, where the gesture lives.
- **Browser** is **pushed/presented** for research and dismissed back to the *precise* same
  active candidate — because selection is feature-model state, not a navigation entry
  (avoids the nested-navigation pop trap noted for iPad detail panels).

The continuity that matters is the research session and the active candidate, not identical
layouts.

### D8 — A general "evaluate a set of unresolved places" surface, scoped to the handoff in v1

The surface's inputs are a **set of candidates + a resolution capability + commit actions** —
none of it AI-specific. The same loop fits ADR-0018 discovery results, a pasted list, or a
friend's shared itinerary. So build the surface **general in shape** (it takes a candidate
set and does not hard-code the handoff as its only feed) but **scope v1 to the handoff set**,
its one real consumer — the YAGNI-respecting form of "the second feed is free later."

Per house style, the workspace is a thin `@Observable` feature model; the **pure
traversal/selection/decision logic** (which candidate is active, what leaves the queue, the
canonical next) lives in the GalavantSchema functional core as tested value types, not in the
model (watch-for-fat-models).

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **Reuse the Ideas shopping surface as-is** | Rejected — that surface browses a *trusted pool*; this processes an *untrusted incoming set* with a per-candidate resolve/research/decide loop. Different job; shares components (map, resolve gesture, browser), not the screen (ADR-0036 D8). |
| **Co-equal map + browser split** | Rejected — both want the stage, and the want/don't-want decision is made in the browser (photos/site). Map is a fast locate-and-confirm; browser is primary (D1). |
| **A pure swipe deck (one card at a time)** | Rejected — loses the set overview you need to compare and pace. Persistent rail + one active selection keeps the set present *and* the momentum (D1/D2). |
| **A pure list (tap around, no active binding)** | Rejected — the always-one-selected invariant is what drives the map + browser coherently and makes the iPhone story a layout change (D1/D7). |
| **Require resolution before Save to Ideas** | Rejected — an unresolved candidate is still useful; forcing a map match to jot it down is friction. Save = shortlist the trip-scoped `TripIdea`; the pool stays clean because only resolution mints an `Idea` (D6). |
| **A new "dismissed" candidate status** | Rejected — dismiss = delete-with-undo; a status column is machinery for an undo the platform already gives (D6). |
| **A bespoke place-search for resolution** | Rejected — the capture matcher already does region-biased `MKLocalSearch` + confirm-merge + dedup. Reuse it; Use This Place is that flow with a candidate as its seed (D4). |
| **AI-supplied coordinates/URLs trusted directly** | Rejected — the AI is authoritative for *judgment*, not *facts* (ADR-0036). Facts come from the confirmed `MKMapItem`; the browser target is derived from resolution state (D5). |

## Relationship to prior decisions

- **ADR-0036 (recommendation handoff):** owns the substrate this stands on — the set is the
  device-local handoff record; candidates are `.considering` `TripIdea`s; Slice 2's resolve
  and choose-one **ops** are what this surface calls.
- **ADR-0013 (Ideas shopping surface):** shared map/list components; distinct job (trusted
  pool vs. untrusted incoming set).
- **ADR-0025 (persistent browser + field-capture bar):** the browser surface and the
  write-back enrichment path (D5).
- **ADR-0016 / ADR-0019 (capture matcher + dedup):** the region-biased search and
  confirm-merge behind Use This Place (D4).
- **ADR-0035 (alternatives ring):** "choose one" promotion (D6); muted/emphasized pin
  language (D3).
- **ADR-0010 (freeform stops):** an unresolved candidate added to the itinerary is a freeform
  stop, upgraded on resolution (D6).
- **ADR-0004 (explicit pull):** the model proposes; every graduation is a human tap.

## Consequences

- **App (the surface):** a three-pane iPad layout (rail · map · browser, browser-weighted)
  and the iPhone sequential variant (map + candidate sheet home, pushed browser); the
  active-candidate feature model; auto-load-lazy browser targeting; the Use This Place flow
  wired to the capture matcher; Save/Add/Dismiss wired to ADR-0036 Slice 2 ops. Built for the
  iPad Pro 13-inch (M5) sim; `swiftui-specialist` checkpoint.
- **GalavantSchema (pure, test-first):** the traversal/selection/decision core as value types
  (active/next/what-leaves-the-queue); unit-tested — selecting is total over a non-empty set,
  dismiss removes and re-selects deterministically, an unresolved candidate is a valid saved
  state, resolution sets `ideaID` without touching rationale.
- **Reuse, not new:** map components (ADR-0013), browser (ADR-0025), matcher/dedup
  (ADR-0016/0019), ring (ADR-0035). No synced entity, no second ingestion path (ADR-0036).
- **Verification:** schema tests in-memory for the traversal core + the two-layer
  preservation; one elevated iOS build; **device pass** for the real loop — open a returned
  set, select, research, Use This Place, save/add/dismiss, resume after backgrounding.

## Slices

- **Slice 1 — the rail + selection over the set (no map/browser yet).** The three-pane
  scaffold; the candidate rail from the handoff set; the always-one-selected model; the
  traversal core; Save/Dismiss wired to ADR-0036 ops. Proves the inbox loop end-to-end on the
  simplest surface.
- **Slice 2 — the map layers + Use This Place.** The three-layer map (D3); the region-biased
  search + confirm-merge (D4); resolution status in the rail; two-layer preservation verified.
- **Slice 3 — the browser + write-back.** State-driven targeting (D5); auto-load-lazy; the
  field-capture write-back for the official URL; Add-to-itinerary (freeform → upgrade) and
  choose-one → ring.
- **Slice 4 — iPhone presentation.** The sequential layout over the identical model (D7).

## Open questions

- **OQ1 — rail affordance for pacing.** Does the rail need explicit next/skip (keyboard on
  iPad) beyond tap-to-select, or is tap enough? Decide from the first real set's size in
  dogfooding.
- **OQ2 — map result confidence UI.** When the region-biased search returns several plausible
  `MKMapItem`s, how much is auto-highlighted vs. left to the human? Lean: highlight the top
  match, require the tap. Confirm on device.
- **OQ3 — set clutter at scale.** A 12-candidate set across a wide region plus itinerary
  geography may be noisy. Muted-non-selected pins (D3) may suffice; if not, a
  "selected + neighbors only" map filter is the fallback. Assess with a real dossier.
- **OQ4 — where the workspace opens from.** A returned handoff needs an entry point (a banner
  on the Trip/Ideas screen? a push straight from paste?). Decide at Slice 1 alongside
  ADR-0036's paste door.
- **OQ5 — resolve-time reconcile when the place is already in the trip.** *(Raised 2026-08-14
  from dogfooding — the "Louisiana Museum of Art in both Shortlist and Considering" case; see
  D4.)* When Use This Place resolves a candidate onto a place that is **already a `TripIdea`
  in the same trip** (already shortlisted, already scheduled, or another candidate in this very
  set), what happens to the two rows? The pool `Idea` dedup fires, but you're left with two
  trip-scoped rows pointing at one `Idea`. Options: (a) **merge** — fold the candidate's
  rationale into the existing row and drop the duplicate (preserving both `inlineNote`s, per
  the IdeaInterest merge precedent in `PoolOperations`); (b) **warn and let the human choose**
  ("already on your shortlist — merge, or keep both?"); (c) **allow both** (a place can
  legitimately be both a firm plan and a reconsidered candidate). Lean **(b)** at the resolve
  gesture, defaulting to merge — it's the moment identity first exists and the human is already
  deciding. This is the natural home for the dedup question the paste door structurally can't
  answer. Settle when Phase 2 (Use This Place) is built; decide the merge-vs-keep-both default
  from a real set.
