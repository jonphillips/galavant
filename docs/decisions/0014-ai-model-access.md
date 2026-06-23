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

---

## Amendment — multi-provider + a model switcher (2026-06-23)

*The "real need" the base ADR's last open item gated on has appeared.*

### Context

Two concrete needs (from Jon, 2026-06-23): **resilience** — the app must stay usable
if a Claude key runs out of tokens or the provider is down — and a **cross-model
second opinion** — develop a plan with one model, then ask a *different* model to
evaluate it. Both want more than one frontier provider behind the same boundary. Jon
also flagged that this model-access layer is **cross-app** — it'll be reused across
several of his apps — which makes the extraction posture (below) part of the decision.

The base ADR designed for exactly this: `FrontierProvider` is already an enum,
`APIKeyStore` is already **keyed by provider** (each provider gets its own Keychain
slot), and `ModelTier.frontier(FrontierProvider)` already carries which provider. The
hard architectural call was made. What's actually new here is (a) confirming iOS 27
doesn't supersede this, (b) a routing generalization, (c) the second backend, (d) a
switcher + fallback, and (e) the cross-app extraction plan.

### Does iOS 27 already provide this? (verified against the SDK)

Checked the iOS 27 `FoundationModels.framework` interface directly
(`apple-sdk-headers-authoritative`). Findings:

- **No built-in third-party router.** There is no OpenAI/Anthropic connector, no
  cloud endpoint, no BYO-provider mechanism — nothing matching `url` / `endpoint` /
  `http` / `openai` / `anthropic` in the public surface. iOS 27 will not call a
  frontier provider for us.
- **But iOS 27 newly opened FoundationModels into a protocol seam:** `public protocol
  LanguageModel` + `public protocol LanguageModelExecutor` (with `init(configuration:)`,
  `prewarm`, and `respond(to: LanguageModelExecutorGenerationRequest, model:,
  streamingInto: channel)`), and `LanguageModelSession.init(model: some LanguageModel,
  …)` is generic. So one *could* write a custom executor that routes generation to
  Anthropic/OpenAI and reuse Apple's `@Generable`, `Tool`, `Transcript`, and streaming.
- **Apple also now ships `PrivateCloudComputeLanguageModel`** — a first-class
  `LanguageModel` tier (Apple's privacy-preserving cloud, with its own `availability`
  and `quotaUsage`), distinct from on-device `SystemLanguageModel`.

**Decision: keep our own `ModelClient` as the cross-app core; do not adopt Apple's
`LanguageModel`/`LanguageModelExecutor` for the shared layer.** Rationale:

1. **Portability is the stated goal.** Apple's protocol is Apple-only and iOS-26/27+;
   binding the shared model layer to it forecloses any future non-Apple app or any
   server-side use. Our `ModelClient` + provider-agnostic value types stay portable.
2. **First-beta volatility.** CLAUDE.md already warns first-beta SDKs churn; coupling
   the substrate every AI feature sits on to a brand-new, fast-moving Apple protocol
   is the wrong bet for a foundation.
3. **It doesn't save the hard part.** The real labor is each provider's wire shape
   (auth, request/response JSON, SSE, tool format, web search) — provider-specific
   under *either* approach. Apple's session ergonomics are nice-to-have, not the cost.

The Apple seam isn't wasted, though: a thin **optional adapter** that wraps a
`ModelClient` as a FoundationModels `LanguageModel` (custom executor) can be added
*later, per-app*, for apps that want Apple's session/`@Generable` ergonomics — without
the core depending on it. Deferred until an app actually wants it.

### On-device stays the floor (Jon's second question)

Yes — on-device is incorporated and stays first-class. `.onDevice`
(`OnDeviceModelClient` over `SystemLanguageModel`) is the **always-available floor**:
no key, no tokens, no network. It is therefore the natural *bottom of the fallback
ladder* — the answer to "don't make the app unusable if I run out of Claude tokens"
is that it degrades to on-device, never to nothing. **New opportunity:**
`PrivateCloudComputeLanguageModel` can be added as a **no-BYO-key Apple-cloud middle
tier** (more capable than on-device, still privacy-preserving, still no third-party
key) — a rung between on-device and BYO-key frontier. Optional, additive; not required
for the OpenAI work.

### The decision

1. **Generalize the router.** `TieredModelClient` today holds a single
   `frontier: (any ModelClient)?` and routes *all* `.frontier(...)` to it regardless
   of provider. Change it to a `[FrontierProvider: any ModelClient]` map, route
   `.frontier(provider)` to the matching client, and report availability per provider
   (`isAvailable(_ provider:)`). On-device remains the unconditional floor.
2. **Add `FrontierProvider.openai`** (one enum case; `CaseIterable` so the switcher UI
   gets the provider list for free) and an OpenAI key field in the AI settings surface
   (Keychain storage already keyed by provider — no new storage code).
3. **`OpenAIModelClient` + `OpenAIWire`** — a second `URLSession` backend mirroring the
   Anthropic pair (`AnthropicModelClient`/`AnthropicWire`, ~340 lines together). OpenAI
   differs: `Authorization: Bearer`, different request/response JSON, different SSE
   deltas, different tool-call shape. Past Claude's cutoff → build against **current
   OpenAI API docs**, not memory; keep the wire pure + unit-tested with fixtures
   exactly as `AnthropicWireTests` does.
4. **Model switcher.** A selected default provider/model in settings, plus a
   **per-conversation** override on the chat panel (ADR-0017 already anticipated
   per-conversation tier choice). This is what enables "develop the plan with Claude,
   then open a chat on OpenAI and ask it to critique the plan." Persist the default;
   the per-conversation choice is ephemeral like the chat itself.
5. **Resilience — manual first, automatic optional.** Manual switching covers the
   out-of-tokens case immediately. An **optional automatic cross-provider fallback**
   (catch a quota/`429`/provider-down error in the router → retry the next configured
   provider, then on-device) is a small, well-contained addition in the generalized
   router. Keep it **explicit/surfaced**, never a silent swap that ships data to a
   different provider without the user knowing (consistent with §3's privacy posture).
6. **Web-search caveat.** The ADR-0018 discovery spike relies on Anthropic's
   *server-side* `web_search` tool. OpenAI's web search is a different mechanism
   (Responses API / its own tool), so *discovery-via-OpenAI* is provider-specific extra
   work — **out of scope for the first multi-provider slice.** Plain chat and
   plan-evaluation need no web search and come first.

### Cross-app extraction posture

This is the **portfolio-extraction trigger** (BACKLOG "Portfolio extraction seams";
ADR-0006). `GalavantAI` is already the clean unit: it is **domain-free** — no
`Idea`/`Trip` (those live in `GalavantPlaces`/`GalavantChat`); the `ModelClient`
protocol + `ModelRequest`/`ModelResponse`/`ModelTool` value types are the portable
core. Per "isolate now, extract later," **build the OpenAI provider in `GalavantAI`
as it stands** (don't pre-extract — premature against a single consumer), keep it
domain-clean, and **lift the whole module to a neutrally-named shared SPM package when
a second real app is scaffolded** — a rename-and-move, not surgery. The base ADR's
"Galavant-scoped name is fine because it's app-internal" (Relationship → ADR-0006)
holds *until* that second consumer is real, at which point the neutral-name rule
applies.

**This is a house-level decision, not galavant-local.** The general substrate choice
(portable `ModelClient`, multi-provider, on-device floor, BYO-key) and the extraction
plan should also be recorded in `~/code/jon-platform` — to be written after reading
its `AGENTS.md`/`docs` (CLAUDE.md rule: read jon-platform before proposing architecture
there). This galavant amendment records how *galavant* adopts it.

### Why this and not the alternatives (additions)

| Option | Verdict |
| --- | --- |
| **Adopt Apple's `LanguageModel`/`LanguageModelExecutor` for the shared core** | Rejected for the core. Apple-only + iOS-26/27+ + first-beta-volatile — kills the cross-app/cross-platform portability that's the whole point, and doesn't remove the per-provider wire work. Keep as an *optional per-app adapter* over `ModelClient` later. |
| **`PrivateCloudComputeLanguageModel` instead of BYO-key frontier** | Not a replacement (it's Apple-cloud, not Claude/GPT, and Apple-account-gated), but a good *additional* no-key tier between on-device and frontier. Additive, deferred. |
| **Silent automatic provider fallback** | Rejected as the default. A swap that ships context to a different provider must be surfaced (§3). Automatic fallback is opt-in and visible. |
| **Multi-provider behind our own `ModelClient` + per-provider Keychain + switcher (chosen)** | The substrate was built for it; cost is one wire mirror + a routing generalization; resilience + second-opinion both fall out; stays no-server and portable. |

### Execution outline (for the build session, when greenlit)

- **GalavantAI:** generalize `TieredModelClient` to a provider map + `isAvailable(_:)`;
  add `FrontierProvider.openai`; `OpenAIModelClient` + `OpenAIWire` (+ `OpenAIWireTests`
  mirroring `AnthropicWireTests`); optional router-level fallback with a test.
- **App:** OpenAI key field in `AISettingsView`; a default-provider picker; a
  per-conversation provider toggle on the chat panel.
- **Skill checkpoints:** the `claude-api` skill is Anthropic-only — for OpenAI, use
  **current OpenAI API docs** (web). `swiftui-specialist` for the switcher UI.
- **Suggested executor: Opus** — a second past-cutoff frontier wire + a foundational
  routing change.
- **Verify:** `swift test` green (new wire + fallback tests); app `xcodebuild`
  succeeds; `swiftlint --strict` clean. Frontier paths verified on device with real
  keys for both providers (sim is fine for the request-assembly tests).

### Sequencing note

Independent of M6e (discovery). The high-value, low-risk first slice is **chat +
plan-evaluation across providers (no web search)**; discovery-via-OpenAI is a later,
provider-specific follow-on.
