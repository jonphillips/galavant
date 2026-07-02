# ADR-0031: Actionable chat — turning a conversation into on-screen changes

*Status: proposed — 2026-07-02. Generalizes ADR-0017 (context-aware chat) and makes
ADR-0030 (itinerary-aware suggestions) its first instance. Cross-app: the driving
force lives in jon-platform `docs/ios/actionable-chat.md`; this ADR is the Galavant
home of the decision. **The abstraction is designed and proven in yes-chef, not here**
— Galavant has no honest distill instance today (§3), so building the `(extract →
commit)` framework in Galavant would be pre-extracting against zero consumers. Galavant
ships parity (§6) and adopts the proven abstraction back once yes-chef's advance-prep
forces its shape.*

## Context

The chat panel (ADR-0017) works — on the Trip screen it already answers *with* the
itinerary in view, because the `ChatContext` trip serializer seeds it (no screenshots
needed). But a 2026-07-02 dogfooding eval surfaced the real problem: **the output is
inert.** Prose suggestions with no links, no way to see a place on the map, raw
markdown, a cramped window. In that state the in-app chat is **strictly worse than
opening ChatGPT/Claude directly** — those apps render better and live in a bigger
window.

So the question isn't "make the panel prettier." It's: **why does an in-app assistant
exist at all?** The answer is two things the standalone app can't do:

1. **Seeded context — no screenshots.** Pre-loaded with the on-screen domain objects
   (ADR-0017 already does this).
2. **Actionable output — relate the answer to the work.** Turn the model's answer into
   a **one-tap change to the on-screen object.**

Markdown, tappable links, and window size are **parity** with the standalone app —
necessary, but not the reason to build. Point 2 is the reason, and it's the same need
in yes-chef (the recipe app): *"read the recipe, suggest advance-prep strategies, then
one tap to write a summarized advance-prep plan into the recipe's advance-prep
section."* Different domain, identical shape. This ADR names that shape once.

## Decision

**An in-app assistant earns its place with seeded context + actionable output. Actions
are screen-declared, typed `(extract → commit)` pairs; the model proposes and
structures, the human's tap is the only write.**

### 1. The invariant — propose, never write

No chat turn mutates the trip, the idea, or (in yes-chef) the recipe on its own. The
model produces or extracts *structure*; a **user tap** commits it through a tested
domain op. This is exactly the ADR-0004 explicit-pull / ADR-0018 "the model finds and
structures, it never writes" line — **not relaxed** here, just brought one tap from
committed. Undo is the normal domain undo (unschedule, clear a field).

### 2. The mechanism — screen-declared apply-actions

A screen presenting chat also declares a small **catalog of typed actions**. Each is a
pair:

```
extract:  conversation-so-far  →  structured payload T     (a focused model call)
commit:   T                    →  a tested domain op         (a pure app write)
```

rendered as buttons. The chat stays free-form; "relate it to my work" lives in these
buttons. **Two motions, one concept**, differing only in *when* the extraction fires:

- **Inline-structured (proactive).** The model's primary output *is* the structured
  thing, rendered as cards/rows with an Add button. **This is ADR-0030** —
  itinerary-aware suggestions as place cards with one-tap pull+schedule. ADR-0030
  stands as the detailed spec for this motion; ADR-0031 just names it as an instance.
- **Post-hoc distill (on-demand).** A real conversation happens, then a button runs a
  *second, focused* extraction over the conversation and commits the result. The first
  real instance is **yes-chef's** "Summarize advance prep → section." Galavant distill
  instances follow (candidates below).

### 3. Where each motion is proven

- **Inline-structured — Galavant already owns it:** ADR-0030's suggestion cards
  (specced; sequenced under M6e). No new work here — this ADR reframes, doesn't re-spec.
- **Post-hoc distill — yes-chef proves it first.** Galavant has **no honest distill
  instance today.** yes-chef's *"Summarize advance prep → section"* is a real, wanted
  feature and the natural forcing function; the `(extract → commit)` abstraction is
  designed there (architect: Claude; executor: Codex) against a genuine consumer, not
  speculated here. Galavant *candidates* exist for later (discuss a day → *"Summarize
  into the day's notes"*; discuss an idea's evaluations → *"Distill into notes"*,
  respecting ADR-0026's description-vs-notes split) but are **not chosen** — Galavant
  adopts the abstraction back once it's proven, if a real need appears.

### 4. The cross-app seam

Maps onto ADR-0014 / [[galavant-ai-cross-app-seam]]:

- **Portable (the model layer, `GalavantAI`):** the primitive is *"run a
  grounded/structured extraction, generic-in, decode to `T` out."* Domain-free; no
  `Idea`/`Recipe` crosses it. This is the unit that lifts to a shared package when
  yes-chef needs it.
- **Domain-side (per app):** the **action catalog** and the **tested commit ops**.
  Galavant declares its place-materialize / distill-to-notes verbs; yes-chef declares
  `advancePrep` / `scaleRecipe` / …. Framework shared, verbs not.

### 5. Provider tier

Grounded and reliably-structured actions default to the **Anthropic frontier**
(dependable structured output + server-side web search — the OpenAI path is unwired
for both). **On-device stays the private default** for plain conversation and
pure-summarize distill actions that need no search. Just ADR-0014 tiering applied;
actions degrade predictably without a key rather than becoming unavailable.

### 6. Parity is table stakes, not the decision

The panel must at least *match* the standalone app: render markdown inline
(`LocalizedStringKey` so bold + `[label](url)` links work — today `Text(String)`
prints raw `###`/`**`), an editable **pre-prompt** in Settings spliced into
`ChatModel.systemPrompt()`, and web search wired into the chat's frontier path (today
the chat does **no** web search, so the ChatGPT key is fully ungrounded — this is why
suggestions came back stale and link-less). These ship alongside but are not the
architectural decision.

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **Just render prose better (markdown/links/bigger window)** | Necessary but insufficient. Parity with the standalone app doesn't justify an in-app panel; only actionable output does. Kept as table stakes (§6). |
| **Let the model call write-tools directly** (client tool-use loop mutates the doc) | Rejected. Crosses the propose-never-write invariant (ADR-0004/0018). The **tap** is the write; the tool verbs exist for the later Siri/composability path, not to auto-mutate. |
| **One motion only** (either cards *or* distill) | Rejected. Discovery wants inline-structured cards (ADR-0030); harvesting a conversation wants post-hoc distill (yes-chef advance-prep). Same `(extract → commit)` shape covers both. |
| **A generic "apply this answer" with no typed action** | Rejected. Untyped application is unbounded and unsafe. Each action is a typed extraction → a *tested* commit op, so the write is exactly as sound as any app write. |
| **Write the cross-app pattern as a jon-platform ADR now** | Deferred. The ADR README's bar is "let a real second app force the choice." yes-chef proves it first; promote to a `docs/adr/` cross-app ADR once the seam holds across both. Driving force is captured as prose meanwhile. |
| **Screen-declared typed `(extract → commit)` apply-actions, propose-never-write, two motions (chosen)** | The reason the in-app assistant exists: seeded context + one-tap on-screen change, inside the explicit-decide guarantee, portable across apps. |

## Relationship to prior decisions

- **ADR-0017 (context-aware chat):** the substrate. This ADR adds the *output* half —
  actions — to the *input* half (seeded context) 0017 already built.
- **ADR-0030 (itinerary-aware suggestions):** becomes the **inline-structured
  instance**. Its cards + one-tap pull+schedule are unchanged; 0031 slots it into the
  general frame.
- **ADR-0004 / ADR-0013 (explicit pull / candidate-vs-pulled):** the tap is the write;
  actions that create pool content land candidates, keeping the pull the human's.
- **ADR-0026 (description vs notes):** distill-to-notes actions respect the split.
- **ADR-0014 / [[galavant-ai-cross-app-seam]]:** the extraction primitive stays in the
  domain-free `GalavantAI`; action catalog + commit ops are domain-side. Anthropic
  frontier for grounded/structured; on-device for private summarize.
- **jon-platform `docs/ios/actionable-chat.md`:** the cross-app driving-force home;
  this ADR is the Galavant instantiation, yes-chef the first real consumer.

## Consequences

- **A typed apply-action abstraction in `GalavantChat`:** a screen supplies a catalog
  of `(extract: [ChatMessage] → T, commit: T → tested op)` pairs; the panel renders
  each as a button and runs extract→commit on tap. Testable with a stub `ModelClient`
  (the app target stays untestable — [[galavant-app-target-untestable]]).
- **`GalavantAI`:** nothing new beyond a generic structured-extraction call (the same
  generic-in / decoded-out shape ADR-0018 uses); web-search stays provider-specific
  behind the protocol.
- **App:** action buttons in the chat panel; the parity fixes (§6) in the panel view
  and a Settings pre-prompt editor.
- **Cross-app payoff:** yes-chef gets the machinery when `GalavantAI` lifts and only
  writes its own action verbs + commit ops.

## Slices

The abstraction is built in yes-chef, not Galavant (see status). Galavant's slices are
parity now and adoption later; the abstraction slice lives in yes-chef's own log.

- **Slice 0 — Galavant parity (§6):** inline markdown + tappable links; editable
  pre-prompt in Settings; wire `webSearchMaxUses` into the chat frontier path. Cheap,
  unblocks dogfooding, independent of the abstraction. *Doable in Galavant now.*
- **Slice 1 — yes-chef prerequisite lift:** move `GalavantAI` → a neutrally-named
  shared package under `jon-platform/packages` (the `WebExtractorKit` playbook; it's
  domain-free, so rename-and-move). Record in `EXTRACTION-NOTES.md`. *yes-chef repo;
  architect Claude / executor Codex.*
- **Slice 2 — yes-chef abstraction + first action:** the typed `(extract → commit)`
  apply-action, built against **advance-prep** as the proving instance; learn the real
  shape. *yes-chef repo.*
- **Slice 3 — Galavant adoption:** once the abstraction is proven, conform ADR-0030's
  cards to it and add a Galavant distill action only if a real need appears (§3).
- **Slice 4 — cross-app docs:** promote the pattern to a jon-platform `docs/adr/`
  cross-app ADR once the shape holds across both apps; flip this ADR to accepted.
