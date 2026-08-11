# M6 (Intelligence) — rebaseline and decision gates

**Status:** Rebaselined 2026-08-09.

**Summary:** Galavant has several real intelligence surfaces, but no longer commits
to completing the old M6 sequence as written. Finish M5's two-device/TestFlight gate,
then use real planning behavior to decide the smallest next product change.

**Related:** `ROADMAP.md` (current milestone framing) · ADR-0014 through ADR-0031
(historical decisions and shipped constraints) · `CURRENT_HANDOFF.md` (current queue).

## What exists now

| Class | Current evidence | Boundary |
| --- | --- | --- |
| Deterministic/domain computation | itinerary/read models, `WeeklyHours`, and the meal-aware `StartDaySolver` | Ordinary tested domain logic; not AI. |
| Bounded on-device extraction/refinement | deterministic capture first; `HoursExtractor` and `EvaluationExtractor` only fill what deterministic extraction cannot; `PlaceIntelligence` separately refines a captured page | Narrow, availability-gated model calls. |
| Embedded conversation | `GalavantChat` is presented from both Ideas and Trip planning surfaces, with pool/trip context and a frontier opt-in | Usable current product surface; messages are ephemeral. |
| Frontier research/discovery | `PlaceDiscoveryClient` makes and parses a grounded frontier request | Infrastructure only: no shipped resolution, deduplication, durable discovery flow, or review UI. |
| External deliberation | Yes Chef is dogfooding a conversation that can yield a reviewable product late in the exchange | Evidence for future product evaluation only; no Galavant implementation is implied. |

## Decisions deliberately left open

1. **Embedded chat's role:** retain it as a primary planning surface, make it
   secondary/optional, or remove it after dogfooding. Its presence is real; its final
   product importance is not settled.
2. **`create_idea` authority:** the live chat tool directly saves a candidate Idea.
   Review whether any model-directed durable write must instead stop at a human review
   boundary. Do not assume ADR-0004's trip-pull boundary answers that different
   question.
3. **Discovery direction:** decide from use whether frontier `PlaceDiscoveryClient`
   deserves a real candidate-review pipeline, or whether external conversational
   discovery is the better product surface. Do not build both by momentum.
4. **TravelProfile:** storage, assembly helper, and editor exist, but Settings does
   not present the editor and no model-request construction reads the profile. Decide
   which preference state matters in actual planning, then wire that minimal path.
5. **Trip discussion context:** `ChatContext.trip` intentionally serializes a thin
   itinerary/shortlist/stays projection. Decide from observed conversations whether a
   richer authoritative projection is needed before creating one.
6. **Yes Chef experiment:** treat it as a source of evidence, not a requirement. Do
   not create a handoff schema, `GV-PRODUCT`, return contract, generic handoff
   architecture, a ChatGPT Project setup, or a Jon Platform extraction for Galavant.

## Safe next-up order

1. Complete the M5 real-device/TestFlight verification in `M5-EXECUTION.md`.
2. Choose one bounded follow-up: wire and expose `TravelProfile`, or conduct the
   explicit review of `create_idea`'s durable-write authority.
3. Revisit discovery, chat prominence, and trip-context richness only after enough
   Galavant dogfooding produces evidence.

The older detailed M6 execution sequence was retired because it described work as
pending that has partly shipped and implied downstream product commitments that have
not been earned. ADRs remain intact as their historical record; re-open an ADR only
when a new decision is actually needed.
