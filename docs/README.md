# Galavant docs — the atlas

The map of every knowledge surface in this repo: what each one is **for**, when to
**read** it, and when to **update** it. Per the house rule
(`jon-platform/docs/agent-workflow.md` → "Working docs stay discoverable"), no doc is
homeless: everything that records a decision, a plan, or a design is linked from here.

**If you read one thing to orient: [NEXT_UP.md](NEXT_UP.md)**, the one dispatch. Galavant runs the
architect/executor loop with the jon-platform ADR-0005 document shape: each document has one audience.

---

## The state surfaces — where "what's the status" lives

Memory (`~/.claude`) never tracks status; it defers here. **GitHub PR state is the only status**
(whose turn it is, what's in review); these documents hold the plan around it.

| Surface | Holds | Reader | Update when |
| --- | --- | --- | --- |
| **[NEXT_UP.md](NEXT_UP.md)** | Exactly one dispatch (ADR-0005 template, ~300 words, replaced wholesale) | **Executor** (its only planning input); architect | The completing PR advances it in plan order; a plan PR sets it otherwise |
| **[milestones/](milestones/)** | Milestone build orders and execution briefs (M5, M6, M7 dogfood, M10) | Architect; executor only via `NEXT_UP.md` | A milestone is planned or a slice lands (ledger tick) |
| **[efforts/](efforts/)** | Off-arc briefs (defects, dogfood rounds, features outside a milestone) | Architect; executor only via `NEXT_UP.md` | A brief is written or its status changes |
| **[open-questions.md](open-questions.md)** | Candidates, designed-but-unscheduled work, parked decisions | Architect, Jon — **never the executor** | Anything is noticed, proposed, or parked |
| **[device-passes.md](device-passes.md)** | Jon's real-device and distribution gates | Jon, architect | A gate is owed or clears |
| **[verification.md](verification.md)** | The standing verification commands and gates | Executor | The pattern changes |
| **[ROADMAP.md](ROADMAP.md)** | The milestone arc (M0…M10+) and milestone-level status markers | Architect | A milestone changes state |
| **[DONE-LOG.md](DONE-LOG.md)** | Shipped work, newest first; the completing PR adds its entry naming its branch | Humans; no dispatch reads it | Work merges |
| **[KNOWN-ISSUES.md](KNOWN-ISSUES.md)** | Known bugs, gaps, and unverified-on-device risks | Before assuming something works; triage | A defect/gap is found or fixed |

## The decision & design surfaces — where "why" lives

| Surface | Holds | Index |
| --- | --- | --- |
| **[decisions/](decisions)** | ADRs — ratified architecture/product decisions and their rationale (ADR-0001…). Why-of-record. | [decisions/README.md](decisions/README.md) |
| **[handoff/](efforts)** | Per-effort execution briefs handed to an implementing agent (Codex). Each carries a `Status:` header. | [efforts/README.md](efforts/README.md) |
| **[PRODUCT.md](PRODUCT.md)** | Product vision / what Galavant is and is for | — |
| **[STYLE.md](STYLE.md)** | App-specific style, on top of `jon-platform/docs/ios/swift-style.md` | — |
| Design/topic notes: [trip-canvas.md](trip-canvas.md), [trip-time-model.md](trip-time-model.md), [MINING.md](MINING.md), [scraping-enrichment.md](scraping-enrichment.md), [recovered-requirements.md](recovered-requirements.md), [browser-capture-feedback.md](browser-capture-feedback.md) | Deep-dives on a subsystem or feature | *(to get `Status:`/`Summary:` headers on-touch)* |
| Per-milestone execution briefs: [M5-EXECUTION.md](milestones/M5-EXECUTION.md), [M6-EXECUTION.md](milestones/M6-EXECUTION.md), [M7-DOGFOOD.md](milestones/M7-DOGFOOD.md) | The working plan for a milestone while it's active | *(archive/mark Done when the milestone closes)* |
| Subdirs: [mockups/](mockups), [proposal/](proposal), [reviews/](reviews) | Visual mockups, proposals, review notes | — |

## Surfaces outside `docs/`

| Surface | Holds |
| --- | --- |
| **[AGENTS.md](../AGENTS.md)** (+ `CLAUDE.md` pointer) | How to work in this repo — stack, conventions, what to read first. Source of truth for agent instructions. |
| **`~/.claude` auto-memory** (`MEMORY.md`) | Durable *working knowledge* with no home in the repo: Jon's preferences, feedback/corrections, traps/gotchas, cross-app seams, references. **Not status** — status lives in the state surfaces above. |
| **`jon-platform/`** | The cross-app house layer: `AGENTS.md` (general working agreement), `docs/agent-workflow.md`, `docs/ios/*` (style, sync laws, drift-control), `docs/adr/*` (cross-app ADRs), `SEAM-LEDGER.md` (shared-package extractions). |

---

## Maintaining this atlas

- **Index at creation.** A new decision/design/handoff doc adds its one-line entry here (and
  to its directory index) *in the same change* — the index is kept by ritual, not vigilance.
- **Self-describing headers.** Decision/design/handoff docs carry `Status:` (Designed /
  Dispatched / Done→done-log / Superseded-by X) and a one-line `Summary:` so a reader can
  tell a live doc from a dead one without opening it. Backfill **on touch**, not in a sweep.
- **Search before you author.** `grep -ri <topic> docs/` and cross-link before writing a new
  ADR or design note, so you don't rewrite ground an existing doc covers.
