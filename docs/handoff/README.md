# Handoff briefs

Per-effort execution briefs handed to an implementing agent (usually Codex): the pinned
seams, ordering, and pure/impure split for building a specific ADR or feature. A brief is a
**dispatch document**, not a decision record — the *why* lives in the ADR it implements; the
brief turns that into an executable plan.

**Status** tracks the brief's lifecycle: Dispatched (being built) → Done (shipped; the work
now lives in `DONE_LOG.md` / the code) → Superseded. Per-doc `Status:`/`Summary:` headers are
backfilled **on touch**; the table below is the current index.

| Brief | Implements | Status |
| --- | --- | --- |
| [logical-uniqueness-dedup.md](logical-uniqueness-dedup.md) | ADR-0008 — sync-dedup convergence hardening | Done (shipped) |
| [m9-adr0037-evaluation-workspace.md](m9-adr0037-evaluation-workspace.md) | ADR-0036/0037 — recommendation evaluation workspace (Phases 1–4) | Dispatched — P1–2 done; P3 (browser) + P4 (iPhone) built, **layout in active revision** |
| [trip-view-declutter.md](trip-view-declutter.md) | Trip View / Edit UX declutter | See doc |
| [plan-memoization.md](plan-memoization.md) | Memoize the planning read model and remove repeated travel-graph derivation | Designed — awaiting approach sign-off |
| [today-day-preview.md](today-day-preview.md) | ADR-0038 — preview any trip day in Today (start-of-day) | Done(shipped) |
| [today-execution.md](today-execution.md) | ADR-0039 — Today execution: complete/skip/defer + tap-to-detail | Dispatched |
| [evaluate-geographic-model.md](evaluate-geographic-model.md) | ADR-0045 — Evaluate geography: biased search, candidate anchors, shared map | WS1 shipped (#93); WS2–3 open |

**Authoring a brief:** add its entry here in the same change (index at creation), give it a
`Status:` + one-line `Summary:` header, and link the ADR it implements. See `docs/README.md`
(the atlas) and `jon-platform/docs/agent-workflow.md`.
