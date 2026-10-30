# Galavant Roadmap

**Status:** Reference · **Summary:** the milestone arc in order, and what each milestone is for.

Vertical slices; each milestone ends with something that runs, riskiest unknowns first. This
file holds the arc's order and intent, not status (jon-platform ADR-0005 D11, D13). What's live
is `jon-platform/scripts/outstanding`; what shipped, and when, is [DONE-LOG.md](DONE-LOG.md); what
Jon still owes is [device-passes.md](device-passes.md). The slice-level history, with the old
✅/⏳ markers, is [archive/ROADMAP-2026-10-30.md](archive/ROADMAP-2026-10-30.md).

## The arc

- **M0 — Skeleton that persists** (2026-06-10). Multiplatform app, share-extension stub, local SPM
  package, SQLiteData in the app group container from day one.
- **M1 — The CloudKit bet** (2026-06-12). SQLiteData sync and a travel-party share over the whole
  graph: the architecture proven ([ADR-0001](decisions/0001-cloudkit-instead-of-custom-server.md), [ADR-0003](decisions/0003-shared-travel-party.md)).
- **M2 — The pool.** Travel party, planners, and his/hers interest; places with MapKit search;
  regions and filters; search-first capture.
- **M2→M3 — Adaptive nav shell** (2026-06-12). Tabs on iPhone, sidebar and detail on iPad and Mac.
- **M3 — Trips** (2026-06-20). The certainty pipeline (someday → targeted → dated), pull to
  shortlist, and the day-relative itinerary with travel-time connectors.
- **M4 — Capture from anywhere** (2026-06-18). The pure parser engine, the share extension, and
  images, later lifted into `WebExtractorKit`.
- **M5 — Polish & distribution.** Sync health, pinned reservations, and TestFlight on CloudKit
  Production (2026-10-08, [PROD-CUTOVER.md](PROD-CUTOVER.md)). Its last gate, the two-phone
  checks, is in device-passes.md. Execution: [M5](milestones/archive/M5-EXECUTION.md).
- **M6 — Intelligence** (rebaselined 2026-08-09). Not a linear build: intelligence may capture,
  refine, and explain, but never silently becomes the record. Its designs are ADRs 0014–0018 and
  0030; the unbuilt ones are candidates in [open-questions.md](open-questions.md). Execution:
  [M6](milestones/archive/M6-EXECUTION.md).
- **M7 — Calendar reconciliation.** The shared Apple Calendar is authoritative; Galavant ingests
  and reconciles (ADR-0034, ADR-0041). Dogfood: [M7](milestones/archive/M7-DOGFOOD.md).
- **M8 — Itinerary alternatives.** One slot holds a ring of peer options with one effective
  member (ADR-0035).
- **M9 — Recommendation handoff & evaluation workspace.** Candidate places from an external-LLM
  round trip, processed like an inbox (ADR-0036, ADR-0037), on the shared `LLMHandoffKit`.
- **M10 — Today & Journey.** Pure `TripPlan` projections over WeatherKit (ADR-0038, ADR-0039).
  Execution: [M10](milestones/archive/M10-EXECUTION.md).

Work since M10 runs as efforts ([efforts/](efforts/README.md)), in the index's order.
