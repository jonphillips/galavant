# Efforts

Per-effort briefs (jon-platform ADR-0005 D4) handed to the executor (Codex) via `docs/NEXT_UP.md`: the pinned
seams, ordering, and pure/impure split for building a specific ADR or feature. A brief is a
**dispatch document**, not a decision record — the *why* lives in the ADR it implements; the
brief turns that into an executable plan.

**The root holds only live briefs; the location is the status** (jon-platform ADR-0005 D10).
A live brief's header opens with `Status:` **Designed**, **Ready**, **Dispatched**, or **Blocked**,
then a one-line `Summary:`. Finished, retired, superseded, and parked briefs live in
[archive/](archive/) (moved with `jon-platform/scripts/archive-brief`); it has no index, since the
folder listing and `DONE-LOG.md` cover it. A parked brief also gets a candidate line in
`open-questions.md`. `jon-platform/scripts/outstanding` prints the live view.

| Brief | Implements | Status |
| --- | --- | --- |
| [day-reorder.md](day-reorder.md) | ADR-0054 D4–D6 | Ready |
| [ideas-map-and-guide.md](ideas-map-and-guide.md) | ADR-0044, ADR-0053 D8 (Ideas map and Guide fixes) | Ready |
| [trip-rationale-priority.md](trip-rationale-priority.md) | ADR-0055 D7 | Ready |
| [route-ideas.md](route-ideas.md) | `trip-canvas.md` (ideas along a day's route) | Ready |
| [handoff-menu-adoption.md](handoff-menu-adoption.md) | jon-platform `docs/ios/ui-and-platforms.md` § The AI entry point | Blocked |

**Authoring a brief:** add its entry here in the same change (index at creation), give it a
`Status:` + one-line `Summary:` header, and link the ADR it implements. See `docs/README.md`
(the atlas) and `jon-platform/docs/agent-workflow.md`.
