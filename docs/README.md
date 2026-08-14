# Galavant docs — the atlas

The map of every knowledge surface in this repo: what each one is **for**, when to
**read** it, and when to **update** it. Per the house rule
(`jon-platform/docs/agent-workflow.md` → "Working docs stay discoverable"), no doc is
homeless: everything that records a decision, a plan, or a design is linked from here.

**If you read one thing to orient: [CURRENT_HANDOFF.md](CURRENT_HANDOFF.md).** It is the
single source of truth for what is active, next, blocked, or designed-but-unbuilt.

---

## The state surfaces — where "what's the status" lives

These are the **one true source** for project status. Memory (`~/.claude`) never tracks
status; it defers here.

| Surface | Holds | Read when | Update when |
| --- | --- | --- | --- |
| **[CURRENT_HANDOFF.md](CURRENT_HANDOFF.md)** | Open granular work — on-deck / in-progress / blocked / designed-not-built. Ordered active-first. Each entry stands alone (actable cold). **The one true "what's active now."** | Starting any session; deciding what's next | Work starts, changes state, or a new effort is designed |
| **[ROADMAP.md](ROADMAP.md)** | The milestone plan (M1…M9+) and milestone-level status markers (⏳/✅) | You need the arc, not the granular queue | A milestone/slice changes state |
| **[DONE_LOG.md](DONE_LOG.md)** | Shipped granular work, append-only, chronological | You need history/context on something already built | An entry from CURRENT_HANDOFF ships — move it here |
| **[KNOWN-ISSUES.md](KNOWN-ISSUES.md)** | Known bugs, gaps, and unverified-on-device risks | Before assuming something works; triage | A defect/gap is found or fixed |

> **Rule (decided 2026-08-14): status has one home.** When an effort starts, is designed,
> or ships, the CURRENT_HANDOFF / DONE_LOG / ROADMAP entry is what changes — not a memory
> file, not a scattered note. A concurrent multi-milestone moment (e.g. M7 calendar *and*
> M9 handoff both live) is represented by multiple CURRENT_HANDOFF entries, all here.

## The decision & design surfaces — where "why" lives

| Surface | Holds | Index |
| --- | --- | --- |
| **[decisions/](decisions/)** | ADRs — ratified architecture/product decisions and their rationale (ADR-0001…). Why-of-record. | [decisions/README.md](decisions/README.md) |
| **[handoff/](handoff/)** | Per-effort execution briefs handed to an implementing agent (Codex). Each carries a `Status:` header. | [handoff/README.md](handoff/README.md) |
| **[PRODUCT.md](PRODUCT.md)** | Product vision / what Galavant is and is for | — |
| **[STYLE.md](STYLE.md)** | App-specific style, on top of `jon-platform/docs/ios/swift-style.md` | — |
| Design/topic notes: [trip-canvas.md](trip-canvas.md), [trip-time-model.md](trip-time-model.md), [MINING.md](MINING.md), [scraping-enrichment.md](scraping-enrichment.md), [recovered-requirements.md](recovered-requirements.md), [browser-capture-feedback.md](browser-capture-feedback.md) | Deep-dives on a subsystem or feature | *(to get `Status:`/`Summary:` headers on-touch)* |
| Per-milestone execution briefs: [M5-EXECUTION.md](M5-EXECUTION.md), [M6-EXECUTION.md](M6-EXECUTION.md), [M7-DOGFOOD.md](M7-DOGFOOD.md) | The working plan for a milestone while it's active | *(archive/mark Done when the milestone closes)* |
| Subdirs: [mockups/](mockups/), [proposal/](proposal/), [reviews/](reviews/) | Visual mockups, proposals, review notes | — |

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

<!-- TODO(follow-up): BACKLOG.md predates the CURRENT_HANDOFF/DONE_LOG split (2026-07-11).
Verify nothing unmigrated remains, then retire it or fold the remainder in — it's
intentionally unlinked here for now. Also confirm whether M5/M6-EXECUTION are archivable. -->
