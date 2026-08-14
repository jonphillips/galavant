# ADR-0036: Recommendation handoff — candidate places from an external-LLM round-trip, on a lifted handoff core

*Status: accepted — ratified 2026-08-13 (Jon), M9. Origin: a 2026-08-13 design conversation
(Jon's "Idea Dossier" brief). The Galavant instance of yes-chef's **external-LLM handoff** (yes-chef
ADR-0038 *External-LLM handoff* / ADR-0042 *Workbench handoff and the return block*),
one level up from ADR-0031: where ADR-0031 adopts the **in-app** `(extract → commit)`
abstraction back from yes-chef, this adopts the **external round-trip** back. Extends
ADR-0030 (itinerary-aware suggestions) — the external path is the flat-rate sibling of
ADR-0030's in-app one-tap pull. Rides ADR-0004 (explicit pull), ADR-0006 (flat
`TripIdea` columns), ADR-0007 (single-FK / reconcile-on-read), ADR-0010 (freeform
stops), ADR-0014 (tiered `ModelClient`, BYO-key, no server). Composes with ADR-0035
(the alternatives ring **is** the "choose one" return relationship), ADR-0019 (capture
dedup / `mapItemIdentifier` **is** the resolution path), and the Ideas shopping surface
(ADR-0013, shared map/list components). The evaluation workspace the candidate set is
processed in is its own decision (**ADR-0037**, stacked on this one; D8). Cross-app: the
handoff **core lifts to a shared jon-platform package**; see §The lift.*

> **Vocabulary.** A **recommendation handoff** is a device-local, trackable session that
> starts from a Galavant trip context (a day, a lodging stay, a transfer, or the whole
> trip), moves an exported **brief** into a native LLM app (ChatGPT/Claude), lets the
> human converse across many turns, and lands a **return block** of candidate places
> back on the originating context. A **candidate** is what the model *meant* — a fuzzy,
> unresolved place (name + locality + rationale), not yet a real-world POI.
> **Resolution** is the act of matching a candidate to an actual map place and enriching
> it. The unit of work is the **session**, not one prompt→response.

## Context

Jon's brief proposes an "Idea Dossier": Chat supplies judgment and candidate discovery;
Galavant makes those candidates geographically understandable, researchable, resolvable
into real places, and easy to promote into Ideas or the itinerary. Three example asks:
*"what else near Thursday's itinerary?"*, *"what else in this stay's region?"*, *"what
stops along this transfer?"*

**Almost every primitive this needs already exists** — in Galavant, in jon-platform, and
above all in yes-chef, where the same round-trip has been fought out across ADR-0038 /
ADR-0042 / ADR-0043, dozens of amendments, and repeated device passes. The product risk
here is **not** under-building; it is **minting a new synced "dossier" entity and a
second place-ingestion path** when the pieces are already load-bearing elsewhere. This
ADR resists both, and treats the round-trip as the trigger to **lift** yes-chef's handoff
core into a shared package with Galavant as consumer #2.

**Two things are Galavant-specific and genuinely new** and are where this ADR spends its
words: (a) the deliverable is a set of **place candidates** rather than prose, which under
yes-chef's own evolved rule (ADR-0042 Amd 6) returns as **strict JSON**; and (b) a candidate must **resolve** to a real-world POI — a
step recipes never take — which reuses Galavant's **capture** pipeline rather than
inventing an ingestion path. *(All yes-chef ADRs below are referenced by number, not
linked — they live in a separate repository.)*

**The economic thesis is yes-chef's, ratified:** spend a flat-rate ChatGPT/Claude
subscription on heavy multi-turn reasoning instead of the app's own metered `ModelClient`
cloud tier. So the **external paste door is the primary everyday path**; the in-app
`ModelClient` call (ADR-0030's one-tap suggestions) is the instant/on-device sibling, not
the default.

## Decision

**Build the round-trip as Galavant's instance of the external-LLM handoff. Candidates
return as strict JSON, land as freeform `.considering` `TripIdea`s, resolve through the
existing capture merge, and group via the alternatives ring. The model proposes and
structures; the human's tap is the only write. The handoff core is lifted to a shared
package; Galavant writes only its own verbs.**

### D1 — The "dossier" is a device-local handoff session, not a synced entity and not merely a filter

The temporary research object Jon intuited **is** yes-chef's `AIHandoff` record:
`id`, `sourceType`, `sourceID`, `taskType`, `scopeKey?`, `createdAt`, `importedAt?`,
`status`, `schemaVersion`, `exportedPrompt`. It is **device-local — never synced**
(transient working state, sync-safe by omission; the return self-describes via its token,
so a cross-device return still routes off the source's synced UUID). The **kept**
candidates persist as durable `TripIdea`s; the *session* is scaffolding.

Two consequences, both deliberate:
- **No synced "dossier" table**, no winner pointer that can dangle — the same verdict
  ADR-0035 reached against an `AlternativeGroup` side-table, and yes-chef against a JSON
  payload record.
- **The research session's live UI state** — which candidate is active, the browser URL,
  the map center — is **feature-model state, never schema, never synced.** The continuity
  Jon wants (active candidate survives an iPhone drill-down into the browser) falls out of
  keeping that state in the model, not the view. iPad shows map + browser + candidate list
  together; iPhone sequences the same state.

### D2 — Galavant's source and task, mapped onto the handoff

- **`sourceType`** ∈ `{ day, stay, transfer, trip }`. **`scopeKey?`** carries the
  sub-scope (a day number, a stay ID) — the generalization of yes-chef's `dayOffset` /
  `variationID`.
- **`taskType`** starts as a single verb, **`candidatePlaces`**. Everything below is that
  one verb; more verbs (e.g. a region-learnings-only session, §D7) are additive.
- The three example asks are `(sourceType, scopeKey)` pairs against the one verb — they
  cost nothing extra once the seam exists.

### D3 — Candidates land as freeform `.considering` `TripIdea`s; resolution reuses capture; "choose one" reuses the ring

A candidate is **not** an `Idea` in the pool. `Idea` is the durable, cross-trip,
dedup-keyed place record; letting unvetted AI fuzz mint pool `Idea`s (each with `nil`
`mapItemIdentifier`, so "never auto-merge" per ADR-0019) would pollute the shared pool with
near-dupes. Instead:

- **A candidate is a freeform `TripIdea`** (`ideaID == nil`, `inlineTitle` = the model's
  name, `status == .considering`), trip-scoped and disposable — ADR-0010's freeform stop,
  born a rung earlier in the lifecycle. Its session provenance is the handoff `id` (D1);
  no synced batch column is required.
- **The AI rationale widens `inlineNote`.** *(Jon, 2026-08-13.)* The "why this fits / what
  it pairs with" is trip-specific intelligence a generic map service cannot give, and it
  must **not** live on `Idea` (it would leak into other trips referencing the same place).
  A single rationale string per stop is appropriate to widen one note for — unlike
  yes-chef's `Learning`, which needed a table because it is a *growing list*. If the
  rationale ever becomes multiple attributed judgments, that is the signal to give it a
  typed home (at which point it starts to look like an `IdeaEvaluation` with `.inferred`
  confidence, ADR-0015/0016).
- **Resolution is the capture merge, not a new path.** A candidate's `search_hint` is a
  pre-filled capture query; "user taps the correct map result" is the capture
  confirm-merge; routing it through the existing dedup (`mapItemIdentifier` /
  logical-uniqueness, ADR-0019) means a place Galavant already knows **collapses onto the
  existing `Idea`** instead of duplicating. Matching mutates immediately **because** that
  mutation *is* the existing merge op (sets `ideaID`, mints/links the `Idea`, dedups) —
  "immediate" and "reuse the existing flow" are not in tension.
- **"Choose one" mints an alternatives ring.** A return group of interchangeable options
  (`"Plose vs. another mountain excursion"`) becomes an `alternativeGroupID` ring
  (ADR-0035) directly — the leanest possible reuse, and it composes with the solver /
  reconciliation as ADR-0035 already describes. **"Do these together"** earns no model yet
  (YAGNI — ADR-0035's own discipline); it stays prose in the rationale until a feature
  needs it.

### D4 — The return is strict JSON, parsed lossless-or-loud

Under yes-chef's evolved rule (ADR-0042 Amd 6), return format keys off **task shape**: multi-turn "discuss then finalize" advisory prose →
tolerant plain text; **one-shot structured extraction with typed records + provenance →
strict JSON.** A candidate list *is* typed records with provenance (name, locality, kind,
rationale, placement ref), so it returns as **strict JSON** — the reader-feedback /
workbench-draft precedent, which proves JSON survives the paste path when `{…}`-delimited
and curly-quote-salvaged.

- **The parser is the `HoursExtractor` template** ([GalavantPlaces/HoursExtractor.swift](../../GalavantLibrary/Sources/GalavantPlaces/HoursExtractor.swift)):
  slice the outer JSON out of the pasted text, decode to `[TripCandidate]`, degrade
  **loud** (a malformed return stops audibly; it never imports garbage or a silent empty
  set). Candidates land in a **row-grain review sheet** — each edited and committed on a
  tap; **no auto-commit** (ADR-0004 explicit-pull; yes-chef's ADR-0024 human-as-author).
- **The smallest load-bearing fields** (each maps onto an existing column): `name` →
  `inlineTitle`; `locality` → `regionName` **and** the map-search disambiguator;
  `search_hint` → the resolve query; `why`/`fit` → the rationale note (D3); optional
  `day_ref`/`placement_after` → an advisory placement hint (D6). `kind`, `visit`,
  `priority` are accepted-when-present and degrade to defaults (`priority` → `shortlistRank`).
  A missing field never blocks ingestion.

### D5 — The JSON contract lives in the chat app's project instructions, version-marked and echoed

Do **not** ship the candidate schema in every brief. Per ADR-0042 D4, the contract is stated **once, persistently, in the user's ChatGPT/Claude project custom
instructions**, generated from one Core constant and surfaced as a **copy button in
Settings**. The brief shrinks to token + trip context + the verb's ask. A version marker
(`GV-CONTRACT: v1`) is echoed in the return so a stale paste is caught, never silently
mis-parses. This inherits yes-chef's hardest-won anti-drift lesson rather than re-deriving it.
*(Amended 2026-08-14 — see Amendment 1: a missing/older marker now **warns and proceeds**;
only a marker newer than the build stays loud. The strict-JSON decode in D4 is the real
lossless-or-loud guard.)*

### D6 — The paste door never silently writes an itinerary slot (the identity rule)

A candidate **place** carries no Galavant identity — safe to return through the paste door
(the same carve-out that let yes-chef's `workbenchDraft` come back: creation has no IDs to
corrupt). But a `placement_after: stop_812` ref **does** name Galavant identity, and
ADR-0042's invariant — *"the paste door never carries identity"* — governs it. So placement refs are **advisory
hints the human confirms in the review sheet** ("Add after Forestis?"), never a silent
write to a specific slot. This is why Jon's brief was right that placement must stay
**optional**: most recommendations belong to a stay's region or the trip-wide pool, not a
precise position.

### D7 — Learnings are the designed-but-deferred second half

A region session yields two things: **candidate places** (this ADR) and durable **travel
learnings** established in discussion ("the Plose cable car closes Mondays"; "Bolzano is
the rainy-day fallback"). Yes-chef gives learnings a synced `Learning` table with a
two-part `(Deliverable?, Learnings?)` return, learning-only being first-class (ADR-0038
Amd 1). Galavant **inherits the shape but does not build it in slice 1**: the first deliverable is
candidates. When learnings ship, they ride the lifted `Learning` table (§The lift) scoped
to `(sourceType, sourceID)` = a trip or region. Recorded so it is not reinvented.

### D8 — The evaluation workspace is its own surface (ADR-0037), over this substrate

Processing a returned candidate **set** is a distinct, high-context job — not the same as
browsing the stocked pool on the Ideas shopping surface (ADR-0013). Evaluating a candidate
means holding two lenses at once — *does this make geographic sense* (map placement, the
exact pin) and *is this place any good* (its website, its photos) — while the rest of the
set stays in view and you move through it deciding keep / resolve / dismiss. That earns a
**dedicated surface**, designed in its own decision (**ADR-0037**, stacked on this one),
not a binding bolted onto the shopping screen.

What **this** ADR fixes is the **substrate**, and the discipline holds no matter how rich
the screen gets: the surface reads the **device-local handoff record** (D1) and
**`.considering` `TripIdea`s** (D3), and resolves through the **capture merge** (D3) —
**no synced dossier entity, no second ingestion path.** The screen is presentation; the
earlier concern was data-model proliferation, which is independent of it. The surface is
**composed from shared components** (the map view, the resolve-a-pin gesture, the
persistent browser), not forked copies. Its signature interaction — locate a candidate on
the map, confirm its exact pin, and lift the map item's `url` straight into the browser to
judge the photos — **fuses resolution and research into one gesture** (an `MKMapItem`
already carries its website URL, category, and coordinates, so the "grab the URL" step is a
property read, not a scrape). ADR-0037 owns that surface's design; this ADR only guarantees
the data it stands on.

## The lift

The round-trip is Galavant's **WebExtractorKit/CloudSyncKit moment**:
`ai-model-access.md` already mandates *"lift the whole module to a shared package when a
second real app needs it."* Galavant is that second app. The yes-chef handoff code
(`YesChefCore/AIHandoff.swift` and siblings) draws a clean domain-free / domain-coupled
line.

**Stance: lift the stable spine now; leave the churning edges per-app.** The spine has not
churned across a year of dogfooding and is self-contained; the edges are at contract v2.1
with Amd 6 ten days old. Lifting the spine couples Galavant to a stable API; composing the
edges per-app keeps Galavant off the churn. Galavant-as-consumer-#2 is precisely what
forces the two genericizations the spine needs (source/task typing; `scopeKey`).

| Piece | Lifts to shared `LLMHandoffKit`? | Note |
| --- | --- | --- |
| Session record + `Repository` + `status`/duplicate guards | **Lift** — genericized | `sourceType`/`taskType` become **String tokens the app maps**; `dayOffset`+`variationID` → one `scopeKey: String?`. Device-local; app owns (non-)registration. |
| Routing token (`header` / `stripping → RoutedText`) | **Lift** verbatim | Prefix parameterized (`YC-HANDOFF:` → per-app / neutral). Dead-stable UUID-header parsing. |
| Contract **version-marker mechanism** (`marker`, echo, `strippingMarker`, out-of-date error) | **Lift** the mechanism | The `projectInstructions` **text** and per-verb clauses are composed by the app. |
| Return splitting (`splitting` on the learnings marker) + `learningBullets` + `plainText` | **Lift** | Domain-free text mechanics; the learnings-marker convention is generic. |
| `Learning` table + `LearningRepository` + `LearningOrdering` (sparse-rank reorder, exact-dedup `insertNew`) | **Lift** — genericized over source | Clean, self-contained. **Synced**: each app registers it in its own `SyncEngine` list + prod-schema promotion (the CloudSyncKit facade pattern). |
| `PromptMode` / `Destination` / the `prompt`+`discussAsk` assembly skeleton | **Lift** the skeleton | Verb asks injected by the app. |
| `DeliverableFormat` + per-verb ask text; `projectInstructions` body | **Per-app** | Still churning (v2.1). |
| Return-format **choice** (plain-text vs strict JSON) per verb | **Per-app** | The kit provides *both* primitives; the app picks per verb (ADR-0042 Amd 6). Galavant's candidate parser also feeds the pending **`LLMClientKit` JSON-slice** rule-of-three (`HoursExtractor` + `EvaluationExtractor` + this). |
| Every `*Review` payload + the review enum | **Per-app** | Domain payloads. |
| Commit ops (candidate → `TripIdea`; resolve-via-capture; ring) | **Per-app (Galavant)** | The verbs. |

**The lift is multi-repo, honestly:** extract the spine from `yes-chef/YesChefCore` →
new `jon-platform/packages/LLMHandoffKit` → rewire yes-chef to consume it → Galavant
consumes it. This is the same shape as the WebExtractorKit lift and carries the same
"first hosted code, then two consumers" arc. Galavant may **copy-then-consume** for its
first slice if yes-chef's extraction isn't ready — the spine is small enough to port and
back-fill, and Jon works both apps daily (learning flows both ways). The ADR's stance is
*lift*; the *sequencing* (lift-first vs copy-then-lift) is a slice-time call.

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **A new synced `Dossier`/`Candidate` table** | Rejected — a second synced record + lifecycle for a session that is transient working state. Device-local handoff record + `.considering` `TripIdea`s already express it (D1/D3); same verdict as ADR-0035 vs. a side-table and yes-chef vs. a JSON payload record. |
| **Unresolved candidates as pool `Idea`s** | Rejected — pollutes the durable cross-trip pool with `nil`-`mapItemIdentifier` fuzz that "never auto-merges" (ADR-0019). Keep AI candidates trip-scoped until resolution vets them (D3). |
| **A second place-ingestion path for candidates** | Rejected — the capture merge already does fuzzy → map-match → enriched `Idea` with dedup. A candidate is just a pre-filled capture query (D3). |
| **Plain-text editable return** (yes-chef's default) | Rejected for *this* verb — a candidate list is typed records with provenance, the exact case ADR-0042 Amd 6 routes to strict JSON. Plain text would lose `kind`/`priority`/placement structure. (Kept for a future prose verb like region-learnings.) |
| **Ship the JSON schema in every brief** | Rejected — restated per verb (drift), re-sent per hand-off (bloat), must survive N turns. The project-instructions contract + version marker is yes-chef's proven fix (D5). |
| **A distinct evaluation workspace screen** | Accepted, as its own surface (ADR-0037). What is rejected is a *synced dossier entity* or a *second ingestion path* behind it — the screen is presentation over this ADR's substrate, composed from shared components (D8). |
| **In-app metered `ModelClient` as the primary path** | Rejected as *primary* — the flat-rate external round-trip is the economic thesis (ADR-0038). In-app one-tap (ADR-0030) stays the instant/on-device sibling. |
| **Copy the handoff core into Galavant, never lift** | Rejected as the *end state* — Galavant is the second real consumer, the `ai-model-access.md` lift trigger. Copy-then-lift is an acceptable *sequencing*, not a destination. |

## Relationship to prior decisions

- **ADR-0004 (explicit pull) / ADR-0031 (actionable chat):** the invariant holds — the
  model proposes and structures, the human's tap is the only write. This ADR is ADR-0031's
  external-transport sibling; ADR-0031 adopts the in-app `(extract → commit)` back from
  yes-chef, this adopts the round-trip back.
- **ADR-0030 (itinerary-aware suggestions):** the in-app one-tap pull is the metered/instant
  path; this is the flat-rate multi-turn path. Same candidate → `TripIdea` commit shape.
- **ADR-0006 / ADR-0007 / ADR-0010:** candidates are freeform `TripIdea`s — flat columns,
  loose `ideaID` reconciled on read, freeform born a rung before `.considering`.
- **ADR-0013 (Ideas shopping surface):** shared map/list components the evaluation
  workspace reuses; the workspace itself is ADR-0037 (D8).
- **ADR-0019 (capture dedup):** the resolution path (D3).
- **ADR-0035 (alternatives ring):** the "choose one" return relationship (D3) — already shipped.
- **ADR-0014 (tiered `ModelClient`, no server):** the in-app sibling path; the external
  round-trip is *not* a server (it is the user's own subscription, device→provider).
- **Cross-app:** jon-platform `ai-model-access.md` (the lift trigger + `HoursExtractor`
  extraction template), `actionable-chat.md` (framework-shared/verbs-not seam); yes-chef
  ADR-0038 / ADR-0042 / ADR-0043 (the handoff core being lifted).

## Consequences

- **Shared package (`LLMHandoffKit`):** the spine per §The lift — session record + token +
  contract-marker + return-splitting + `Learning`, genericized over `String` source/task +
  `scopeKey`. Extracted from yes-chef; yes-chef rewired to consume; Galavant consumes.
- **GalavantSchema (pure, test-first):** `inlineNote` widened to carry rationale for a
  pulled candidate; a `TripCandidate` value type + strict-JSON decode (HoursExtractor
  pattern, lossless-or-loud, unit-tested with fixtures — no network); commit ops
  (candidate → `.considering` `TripIdea`; "choose one" → ring via existing ADR-0035 ops).
  No new synced table.
- **Device-local handoff store:** the session record is **not** in Galavant's `SyncEngine`
  registration (sync-safe by omission) — confirm the per-table opt-out in `GalavantCloudSync`,
  or a lightweight non-synced store, as yes-chef OQ1 did.
- **Resolution reuses `GalavantCapture` / `GalavantPlaces`** — no new ingestion path.
- **App:** the outbound brief (token + context, contract in project instructions, Settings
  copy-button + `GV-CONTRACT` staleness check); the strict-JSON paste → row-grain review
  sheet; the Ideas-surface active-candidate binding + handoff section (D8); resolve wired
  to the capture merge; `swiftui-specialist` checkpoint; install on the iPad Pro 13-inch (M5)
  sim.
- **Verification:** schema tests in-memory (candidate decode incl. malformed-loud and
  partial-field cases; candidate → `TripIdea`; "choose one" → ring); one elevated iOS build;
  **device pass** for the real external round-trip (copy brief → converse → paste → review →
  resolve → promote), which also settles the contract-in-project-instructions ergonomics.

## Slices

- **Slice 1 — the seam, in-app paste door, one verb.** Device-local handoff record
  (`sourceType`/`scopeKey`/`taskType = candidatePlaces`); outbound brief with `GV-HANDOFF:`
  token; the `TripCandidate` strict-JSON decode (HoursExtractor pattern) → row-grain review
  → commit as `.considering` `TripIdea` (rationale in `inlineNote`). Contract in project
  instructions + Settings copy-button + `GV-CONTRACT` marker. In-app **Copy brief / Paste
  result** door (yes-chef Amd 2 — the everyday path). No resolution yet, no new screen.
- **Slice 2 — resolution ops + "choose one".** "Resolve" wired to the capture merge (dedup
  onto existing `Idea`, lifting the `MKMapItem` coordinates/URL); "choose one" → alternatives
  ring. The *evaluation surface* that drives these is **ADR-0037** — this slice lands the
  tested ops it will call.
- **Slice 3 — the lift.** Extract the spine to `jon-platform/packages/LLMHandoffKit`;
  rewire yes-chef; Galavant consumes. (May be sequenced before Slice 1 as lift-first, or
  after as copy-then-lift — Jon's call at dispatch.)
- **Deferred (designed, not built):** the two-part return with a synced `Learning` home
  (D7); App Intents / `Ask ChatGPT` hands-free transport (yes-chef ADR-0038 D4 — the bonus,
  not the primary door); relationship structure beyond "choose one" (D3).

## Open questions

- **OQ1 — `scopeKey` encoding. — Resolved 2026-08-13 (Jon).** `scopeKey` is a single
  opaque `String?` that **Galavant owns**; `LLMHandoffKit` treats it as an uninterpreted
  token (per §The lift). Encoding by `sourceType`: `day` → the day number as a string
  (`"3"`); `stay` / `transfer` → the record's UUID string; `trip` → `nil` (the source UUID
  already fully scopes it — a trip-wide session has no sub-scope, per D2). Encode/decode
  lives in one Galavant Core helper next to the handoff-record construction, unit-tested
  round-trip; the kit never parses it. This keeps the spine generic (yes-chef's `dayOffset`
  + `variationID` both collapse into the same `String?` slot) while Galavant retains full
  control of the meaning.
- **OQ2 — lift sequencing. — Resolved 2026-08-13 (Jon): copy-then-lift.** Slice 1 ships on a
  **small spine ported locally into Galavant** (the session record + routing token +
  contract-marker mechanism), so Galavant is not gated on the multi-repo yes-chef extraction
  whose edges are still churning (contract v2.1, Amd 6). The local spine's home is
  `GalavantAI` (the domain-free model substrate already destined for yes-chef), which makes
  the eventual lift a clean cut. The lift to `jon-platform/packages/LLMHandoffKit` is
  **Slice 3**, a separate later PR that swaps the local spine for the shared package and
  rewires yes-chef — a refactor with no behavior change, verifiable against the Slice 1
  tests. The ADR's *stance* remains lift; this only fixes the *sequence*. (ADR-0037's
  workspace consumes the ops, not the spine, so it is unaffected by which side of the lift
  Slice 1 lands on.)
- **OQ3 — JSON-slice helper home.** Galavant's candidate decode is the 3rd/4th consumer of
  the messy-text→JSON pattern (`HoursExtractor`, `EvaluationExtractor`, this). Does it trip
  the `ai-model-access.md` rule-of-three lift of a structured-output helper into
  `LLMClientKit`, or copy the slice once more? Assess against the existing two extractors.
- **OQ4 — candidate prose vs. JSON, tested.** 90% confidence it is JSON (D4). Gate on a
  hand-run before wiring import (yes-chef's method): confirm a real candidate return survives
  the paste path as JSON and the row-grain review reads well. If a place candidate proves more
  "editable prose" than reader-feedback was, fall back to the plain-text primitive the kit
  also provides.

## Amendment 1 — the paste boundary is warn-not-block, not fail-loud (2026-08-14, Jon; dogfooding)

D4/D5 originally made **three** things fail loud on paste: the `GV-HANDOFF:` routing token,
the `GV-CONTRACT:` marker, and the JSON decode. Dogfooding showed the first two are friction,
not safety — they reject an otherwise-good paste for reasons that don't protect anything:

- **The routing token is a hint, not an admission ticket.** It only *routes* a return to a
  session record; commit targets the current trip regardless of which session recorded the
  candidates (`TripIdea.commit(into: tripID)`), and the session's scope is advisory (D6). The
  everyday failure is benign: you copy a brief, the sheet dismisses or you start a new handoff,
  and the return carries the old token → `wrongSession` blocked the exact normal flow. **Now:**
  a dropped/mismatched token attaches the candidates to the handoff you're pasting into, with
  a non-blocking warning. Blast radius is bookkeeping.
- **The contract marker is redundant with the decode for the versions that exist.** With only
  `v1`, a missing or reformatted marker tells you nothing the strict-JSON decode won't catch
  on its own. **Now:** missing or *older-than-current* marker → warn and proceed; the decode
  stays the real lossless-or-loud guard. The one case kept loud is a marker **newer** than the
  build understands (a future `v2` return hitting a `v1` app) — that's the only case where
  proceeding could silently misread a schema. Rule: *unknown-future = stop; known-or-missing =
  warn and proceed.*

Only **the JSON decode** (D4) remains fail-loud; it is what actually prevents importing
garbage. Warnings surface as a non-blocking "Imported with a note" alert.

**"If I know what I'm doing, I know what I'm doing"** is the governing principle for this
door — the guards that stayed are the ones that catch a genuine data-loss/misparse, not the
ones that enforce ceremony. Shipped on branch `m9-handoff-warn-not-block`
(`HandoffContractMarker.strippingMarker` now returns a `HandoffContractResult` with an
optional warning; `pasteRecommendationResult` treats routing as a fallback). This is a
**boundary-behavior** change, not a spine change — the lift (Slice 3) carries it forward
verbatim: the kit's marker mechanism returns a warning instead of throwing, and the app
composes the copy.
