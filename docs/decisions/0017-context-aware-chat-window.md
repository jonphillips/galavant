# ADR-0017: Context-aware chat window over the current screen

*Status: accepted — 2026-06-22*

## Context

M6d, the conversational surface of the AI strategy (ROADMAP M6; the 2026-06-22 chat).
Jon wants to **discuss what's on screen** — an idea and its evaluations/ratings, a
trip's itinerary, the filtered pool — with a model, and to ask pool-wide questions
("which Denmark food ideas haven't we visited?"). It's the most visible M6 slice and
the one that most exercises the substrate, so it lands last: it leans on ADR-0014
(the tiered `ModelClient`, streaming, BYO-key), ADR-0015 (the taste profile +
evaluations as context), and the App Intents pool verbs from the "AI pool-stocking"
BACKLOG entry.

The spine still holds: AI **explains and helps**; Jon still decides and pulls. The
chat answers and proposes; it doesn't silently mutate the trip.

## Decision

**A context-aware chat panel, backed by ADR-0014's tiered `ModelClient`, seeded with
the current screen's domain objects and given the pool/trip verbs as tools. Privacy
tier is a surfaced, per-conversation choice; on-device is the default.**

### 1. Backed by the tiered `ModelClient` (ADR-0014) — chat is its first `stream` consumer

The panel calls `ModelClient.stream(_:)`. **On-device by default** (`FoundationModels`
— private, offline, free); **frontier (BYO-key) opt-in per conversation** ("Discuss
privately" vs "Discuss with Claude"). A frontier conversation uses the URLSession SSE
client against `/v1/messages`, default **`claude-opus-4-8`** for its reasoning; verify
the streaming + tool-use loop shapes against the `claude-api` skill at build (past
Claude's cutoff). If no frontier key is configured, only the on-device option shows.

### 2. Context = the visible domain objects, serialized per screen

Each screen supplies a **`ChatContext`** — the model is seeded, not turned loose on
the database:

```swift
/// What the chat is "looking at." Built by the presenting screen from already-
/// fetched read-model values; serialized into the system/context prompt.
public enum ChatContext: Sendable {
  case idea(ResolvedIdeaContext)   // the idea + its IdeaEvaluations + his/hers IdeaInterest + tags
  case trip(TripPlan)              // the resolved itinerary read-model
  case pool(PoolContext)           // the current filter lens + visible ideas
}
```

This keeps context **bounded and accurate** (it's the same read-model the view
renders) rather than hoping the model queries correctly. The **taste profile**
(ADR-0015) is injected by the `ModelClient` boundary into every call, so the chat
reflects Jon/wife's taste without the panel re-plumbing it.

### 3. Tools = the pool/trip verbs (shared with App Intents)

For questions beyond the seeded context, the chat calls **tools** — the same verb
vocabulary the "AI pool-stocking" BACKLOG entry defines as App Intents
(`findPlaces`, `queryPool`, `createIdea`, later `scheduleStop`). Defined once over the
**tested `GalavantSchema` core**, they serve Siri/Shortcuts *and* the chat's tool
surface, so "which Denmark food ideas haven't we visited?" is a real query over the
pool, **not a hallucination**.

**v1 ships read-leaning tools** — `queryPool` (NL filter over ideas) and `createIdea`
(which lands a **candidate** idea per ADR-0013, preserving the pull boundary). Trip
*mutation* verbs (`scheduleStop`) are deferred until the read surface proves out; the
chat proposes scheduling, Jon performs it. On-device tool-use is limited; the richer
tool loop is a frontier-tier capability (the model emits `tool_use` → the app runs the
verb → returns `tool_result` → continues; `claude-api` skill for the loop).

### 4. Privacy is a surfaced choice; conversations are ephemeral

- **Frontier sends the serialized context (pool/trip data) to the provider.** That is
  acceptable for a private two-person app **with eyes open** — the panel names the
  tier and shows that data leaves the device before a frontier call; on-device is the
  private default. Never silent.
- **Conversations are ephemeral for v1** — per-session, not persisted or CloudKit-
  synced. A chat isn't durable pool content; keeping it out of the synced store avoids
  privacy/BLOB complications and matches the model's stateless API (resend history per
  turn). Persistence can come later if wanted.

### 5. UI placement

A model-driven panel invoked from a screen (idea detail, trip canvas, Ideas screen),
carrying that screen's `ChatContext` — a sheet on iPhone, a side panel on iPad/Mac
(reuse the `horizontalSizeClass` split the trip canvas already uses; **not** a nested
`NavigationStack` in the iPad detail — `ipad-nested-navigationstack-trap`). Not a new
top-level nav section.

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **Frontier-only chat** | Rejected. Forces every musing off-device and costs money for questions the on-device model can answer. Frontier is opt-in, not mandatory. |
| **On-device-only chat** | Rejected as the ceiling. Private, but can't do the multi-source reasoning or tool-rich answers the frontier tier gives. Kept as the default tier. |
| **Let the model query the DB freely (no seeded context, no typed tools)** | Rejected. Unbounded and hallucination-prone. Seeded `ChatContext` + typed verbs over the tested core keep answers grounded. |
| **Chat can schedule/mutate trips directly in v1** | Rejected for v1. Crosses the explicit-pull/decide boundary (ADR-0004). Read + propose first; `createIdea` only lands a candidate (ADR-0013). |
| **Persist + sync conversations** | Deferred. Not durable pool content; ephemeral avoids CloudKit/privacy cost. Revisit if a real need appears. |
| **Tiered panel, seeded context, verbs-as-tools, ephemeral (chosen)** | Capable when wanted, private by default, grounded, and inside the no-server / explicit-pull guarantees. |

## Relationship to prior decisions

- **ADR-0014 (model access):** the chat is the first real `stream` consumer; tier
  choice, BYO-key, and profile injection all come from that boundary. No new server.
- **ADR-0015 (evaluations + profile):** evaluations + his/hers ratings are part of the
  idea `ChatContext`; the taste profile shapes every call.
- **ADR-0013 (candidate pins):** a chat `createIdea` lands a **candidate**, keeping the
  pull decision Jon's.
- **ADR-0004 (explicit pull):** v1 tools read and propose; trip mutation stays manual.
- **ADR-0001 / ADR-0003 (no server / shared party):** device→provider with the user's
  key; sending shared pool data to a provider is a conscious, surfaced choice.
- **`ipad-nested-navigationstack-trap`:** the iPad panel is an overlay/side column, not
  a nested stack.

## Consequences

- **A `ChatModel`** (`@Observable`) driving the `ModelClient` stream, holding the
  `ChatContext`, tier choice, and ephemeral message list; lives in the SPM package so
  the tool-dispatch + context-serialization logic is testable with a stub
  `ModelClient` (the app target stays untestable — `galavant-app-target-untestable`).
- **Tool definitions** over `GalavantSchema` shared with the App Intents work; v1 =
  `queryPool` + `createIdea` (candidate), `scheduleStop` deferred.
- **`ChatContext` providers** per presenting screen (idea / trip / pool), built from
  the existing read-models.
- **A chat panel** (iPhone sheet / iPad side column) with a clear tier indicator and
  an explicit "data leaves the device" affordance on the frontier path.
- **Open at build:** the exact v1 tool set; whether on-device tier supports enough
  tool-use to be useful or is chat-only with frontier carrying tools; chat persistence;
  per-screen invocation affordances.
