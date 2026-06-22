# ADR-0014: AI model access — tiered, on-device + BYO-key frontier, no server

*Status: accepted — 2026-06-22*

## Context

Galavant is growing an AI strategy (the 2026-06-22 design chat; BACKLOG "AI
pool-stocking", "AI assistant / chat"): source-attributed evaluations extracted on
capture, on-demand field enrichment ("supplement hours"), a customizable taste
profile injected into prompts, and a context-aware chat window over the current
screen. Every one of those features calls a language model. Before building any of
them we need one decision about **how the app talks to models**, because they all
sit on it.

Two forces pull against each other:

- **ADR-0001 says no custom server** — CloudKit only, no backend Jon operates, no
  auth system, no shared secret. That is load-bearing: it's why V1/V2 stalled and
  why V3 ships.
- **The capable models live behind network APIs** (Anthropic, OpenAI) and the
  private/cheap model lives on-device (Apple's `FoundationModels`, already wrapped
  as `PlaceIntelligence` in `GalavantPlaces`, ADR — M4d).

The question is whether reaching for a frontier API breaks the no-server property.
It does **not**, and pinning down *why* is this ADR's job.

## Decision

**AI features call models through one injectable, tiered `ModelClient` boundary.
Two tiers: on-device (`FoundationModels`, free/private/offline) and frontier
(Anthropic/OpenAI over the network, authenticated with the *user's own* API key in
the Keychain). No model traffic ever passes through infrastructure Jon operates.**

### 1. "No custom server" (ADR-0001) is preserved — the boundary interpretation

A third-party model API is **not** a custom server in ADR-0001's sense. ADR-0001
forbids *infrastructure Jon stands up and maintains* — a backend, a sync engine, an
auth/login system, a shared secret to rotate. A direct device→Anthropic call has
none of that:

- **No backend.** The device calls `api.anthropic.com` directly; there is nothing
  in between to deploy, scale, log, or debug.
- **No auth system, no shared secret.** Each device authenticates with **its user's
  own API key**, stored in the Keychain (and synced across that user's devices by
  iCloud Keychain — the same "the iCloud account is the identity" model ADR-0001
  already relies on). Jon's devices use Jon's key; his wife's use hers (or a shared
  one — her call). No key is ever shipped in the app, embedded in a record, or
  synced as travel-party data.

This is the one credential that is **device-local, not travel-party-shared** — a
deliberate, named exception to ADR-0003 ("everything is party-shared"). An API key
is a personal access credential like the iCloud login itself, not shared trip
content. It lives in the Keychain, never in a SQLiteData/CloudKit table.

What stays ruled out (unchanged): a proxy or relay Jon runs, a shared org key baked
into the app, any server-side orchestration, any model call that depends on
infrastructure being up that isn't Apple's or the provider's. **If no frontier key
is present, the app degrades to on-device only — it never silently falls back to a
hosted Galavant service, because there isn't one.**

The other two mechanisms this strategy leans on are even more clearly in-bounds:
**on-device models** (Apple frameworks) and **on-device web fetch** (a `WKWebView`
the user drives, for the "supplement from the page" enrichment) — neither touches a
server at all.

### 2. The `ModelClient` boundary

One protocol, injected like every other I/O boundary (`PlaceSearchClient`,
`directionsClient`, `PlaceIntelligence` — see [inject-io-boundaries-early]):

```swift
/// The single seam every AI feature calls through. Injectable so feature logic is
/// testable with a stub and the backend (on-device vs frontier) is a config choice,
/// not a call-site choice.
public protocol ModelClient: Sendable {
  /// One-shot completion (extraction, classification, summarize, recommend).
  func complete(_ request: ModelRequest) async throws -> ModelResponse
  /// Token stream for the chat window.
  func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelChunk, any Error>
}

public enum ModelTier: Sendable {
  case onDevice                  // FoundationModels — free, private, offline
  case frontier(FrontierProvider)  // Anthropic / OpenAI — user's key, networked
}
```

Implementations: `OnDeviceModelClient` (wraps the existing `PlaceIntelligence`
plumbing / `FoundationModels`), `AnthropicModelClient`, optionally
`OpenAIModelClient`. A small router picks a tier per task (§3). Lives in the SPM
package (a focused module — name decided at build, ADR-0006 keeps it
Galavant-scoped since it's app-internal) so it's unit-testable with a fixture
backend, exactly as `PlaceSearchModelTests` overrides `PlaceSearchClient`.

**Swift has no official Anthropic SDK.** `AnthropicModelClient` is a thin
`URLSession` client against `POST https://api.anthropic.com/v1/messages` —
`x-api-key: <user key>`, `anthropic-version: 2023-06-01`, SSE for the streaming
chat path. Default model **`claude-opus-4-8`** (1M context); `claude-haiku-4-5` for
cheap/bulk frontier calls; `claude-fable-5` reserved for genuinely hard reasoning.
Verify model IDs / API shape against current docs at build (past Claude's cutoff —
the `claude-api` skill is the in-repo reference).

### 3. Tiering policy — cheap/private on-device, capable/opt-in frontier

| Task | Default tier |
| --- | --- |
| Capture extraction, dedup, `IdeaKind` classification, note cleanup, embeddings, cheap summaries | **on-device** |
| Multi-source reasoning, recommendations, the chat window | **frontier** (BYO-key) |

- On-device is the **default for anything cheap, private, or offline-capable** — it
  costs nothing, ships no data off-device, and is already in the stack.
- Frontier is **opt-in and conscious.** The chat window offers "discuss privately
  (on-device)" vs "discuss with Claude (your key)" per conversation (the
  tiered-both posture from the 2026-06-22 chat). A frontier call **sends the
  serialized context to the provider** — acceptable for a private two-person app
  *with eyes open*, never silent. If no key is configured, frontier options are
  disabled and on-device is offered instead.

### 4. The taste profile feeds every call (forward ref)

A forthcoming ADR adds a `TravelProfile` (shared party + per-planner overlay; the
2026-06-22 decision). The `ModelClient` boundary is where it's injected: request
construction assembles the system prompt from the profile so "Jon skews luxury, his
wife skews food" rides every call without each feature re-plumbing it. Named here so
the boundary is designed for it; the record itself is the next ADR's scope.

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **On-device only** | Rejected as the *whole* answer. Private and offline, but `FoundationModels` can't do the chat window's multi-source reasoning or good discovery. Kept as one tier, not the ceiling. |
| **Frontier only** | Rejected. Every cheap classification would cost money and a round-trip, and would ship private pool data off-device for tasks the on-device model handles for free. |
| **A Galavant proxy holding one shared key** | Rejected — it *is* the custom server ADR-0001 forbids: infra to run, a secret to rotate, a thing that can be down. BYO-key in the Keychain gets the same capability with none of it. |
| **Embed an app-wide API key** | Rejected. Unshippable safely even for two users, and it's a shared secret — exactly what ADR-0001/0003's "no shared secret, iCloud is identity" rules out. |
| **Tiered, on-device + BYO-key frontier (chosen)** | Capability when wanted, privacy/cost by default, and the no-server / no-auth / no-shared-secret properties all survive. |

## Relationship to prior decisions

- **ADR-0001 (no custom server):** *upheld and interpreted*, not weakened. Third-
  party model APIs via BYO-key add no infrastructure Jon operates. The boundary is
  now explicit: no proxy, no shared key, no hosted fallback.
- **ADR-0003 (everything travel-party-shared):** *narrow named exception.* The
  frontier API key is device-local Keychain state, not party-shared data — like the
  iCloud account itself. No ownership flags return; this is a credential, not
  content.
- **ADR-0006 (naming):** the new SPM module is app-internal, so a Galavant-scoped
  name is fine; the neutral-name discipline is for cross-app packages only.
- **M4d / `PlaceIntelligence`:** generalized. The on-device `FoundationModels`
  client that M4d introduced for capture becomes `OnDeviceModelClient`, one tier
  behind the new boundary, rather than a place-specific one-off.
- **[inject-io-boundaries-early]:** same pattern — wrap the I/O (now the model) in
  an injectable client in the package from first use, so it's testable.

## Consequences

- **New SPM module** holding `ModelClient`, the tier enum, request/response value
  types, and the three backends; unit-tested with a stub backend (no network, no
  device model) per the package-home pattern.
- **Keychain key storage** + a settings surface to enter/clear per-provider keys
  (lands with the "You"/settings area BACKLOG already wants). Absent a key →
  frontier disabled, on-device offered.
- **Every later AI feature** (evaluations extraction, supplement-from-page, chat)
  targets this boundary, not a provider directly — swapping providers or adding a
  tier is a backend change, not a call-site sweep.
- **Privacy is a surfaced choice**, not a default — the chat window names which tier
  (and therefore whether data leaves the device) before a frontier call.
- **Cost is the user's**, bounded by their own key; no Galavant billing surface.
- **Open at build:** the SPM module name; exact `ModelRequest`/`ModelResponse`
  shape; whether OpenAI ships in v1 or Anthropic-only first (lean Anthropic-only —
  `claude-opus-4-8` default — and add OpenAI behind the same protocol only if a
  real need appears).
