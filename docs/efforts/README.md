# Efforts

Per-effort briefs (jon-platform ADR-0005 D4) handed to the executor (Codex) via `docs/NEXT_UP.md`: the pinned
seams, ordering, and pure/impure split for building a specific ADR or feature. A brief is a
**dispatch document**, not a decision record — the *why* lives in the ADR it implements; the
brief turns that into an executable plan.

**Status** tracks the brief's lifecycle: Dispatched (being built) → Done (shipped; the work
now lives in `DONE-LOG.md` / the code) → Superseded. Per-doc `Status:`/`Summary:` headers are
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
| [dogfood-now-and-sketch.md](dogfood-now-and-sketch.md) | Dogfood 2026-09-11 — sense of *now*, device location, stay notes, general connectors, Today non-stop events, trip sketch | Done (all seven slices shipped) |
| [trip-sketch-design.md](trip-sketch-design.md) | ADR-0012 — trip sketch (days × regions), Slice E of the dogfood brief | Done (shipped) |
| [evaluate-duplicate-candidate-sets.md](evaluate-duplicate-candidate-sets.md) | Dogfood 2026-09-28 item 2: re-paste duplicates candidates and orphans resolved rows | Done |
| [booking-scope-4-hint-and-today.md](booking-scope-4-hint-and-today.md) | ADR-0047 Scope 4 — handoff "book ahead" hint seeds To book; Today "Still to book" card | Done (2026-09-29) |
| [today-day-map.md](today-day-map.md) | Dogfood B2 — a glanceable day map on Today (route, base, next, device in the union frame; ADR-0046 §5) | Done (2026-09-29) |
| [today-polish.md](today-polish.md) | Review follow-ups from #145/#143 — live-day map keeps the device across a day rollover; `bookingsDue` doc comment | Done (2026-10-04) |
| [adr-0048-slice-1-declined-and-documents.md](adr-0048-slice-1-declined-and-documents.md) | ADR-0048 Slice 1 — `.declined` status (ruled out, with reason) + synced read-only trip documents | Done (2026-10-04) |
| [iphone-trip-presentations.md](iphone-trip-presentations.md) | Dogfood 2026-10-06 — trip sheets dropped on iPhone (outer host already presenting); Ideas empty-state overlay covers rows | Done (2026-10-06) |
| [adr-0048-slice-2-seed-verb.md](adr-0048-slice-2-seed-verb.md) | ADR-0048 Slice 2 — seed verb: contract v2, `SeedReturn` decode, `SeedPlan`, bulk review, one-transaction commit | Done (2026-10-06) |
| [adr-0048-slice-3-seed-matching.md](adr-0048-slice-3-seed-matching.md) | ADR-0048 Slice 3 — seed matching: saved ideas then map, Confirm Obvious Matches, research notes → `IdeaEvaluation` | Done (2026-10-07) |
| [adr-0049-s1-backup-restore.md](adr-0049-s1-backup-restore.md) | ADR-0049 S1 — adopt `CloudSyncKit` backup & restore: migrate-by-path, facade config, owner-only Settings Backup section, restore-held sync row | Done (2026-10-07) |
| [codex-recommendation-brief-stops.md](codex-recommendation-brief-stops.md) | Recommendation brief stops (moved from `docs/handoffs/`) | See doc |

**Authoring a brief:** add its entry here in the same change (index at creation), give it a
`Status:` + one-line `Summary:` header, and link the ADR it implements. See `docs/README.md`
(the atlas) and `jon-platform/docs/agent-workflow.md`.
