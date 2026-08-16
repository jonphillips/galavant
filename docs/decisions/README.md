# Decision log (ADRs)

Ratified architecture and product decisions, with their rationale — the **why-of-record**
for Galavant. One file per decision, numbered in order of adoption. Superseded decisions
stay (they explain how we got here); the newer ADR links back with a `Supersedes:` note.

**Before authoring a new ADR:** `grep -ri <topic> docs/` and read the adjacent decisions and
design notes — cross-link them. Add the ADR's one-line entry here in the same change (index
at creation). See `docs/README.md` (the atlas) and `jon-platform/docs/agent-workflow.md`.

| ADR | Title |
| --- | --- |
| [0001](0001-cloudkit-instead-of-custom-server.md) | CloudKit via SQLiteData instead of a custom server |
| [0002](0002-pointfree-stack-no-tca.md) | Point-Free libraries, but not TCA |
| [0003](0003-shared-travel-party.md) | One fully-shared travel-party library |
| [0004](0004-pull-based-trip-membership.md) | Pull-based trip membership; regions, not boards |
| [0005](0005-platforms-capture-distribution.md) | Platforms, capture, and distribution |
| [0006](0006-naming.md) | Domain vocabulary |
| [0007](0007-attribution-and-sharing-fks.md) | Per-planner attribution, and the single-FK sharing rule |
| [0008](0008-second-device-identity.md) | Second-device identity and sync-duplicate hardening |
| [0009](0009-image-storage-and-processing.md) | Image storage & processing |
| [0010](0010-freeform-itinerary-stops.md) | Freeform itinerary stops — a stop is not always a pulled idea |
| [0011](0011-accommodations-as-stays.md) | Accommodations are stays, not point stops — a sibling `TripStay` |
| [0012](0012-per-day-region-framing.md) | A region is a per-day attribute driving idea-scope and the empty-day map frame |
| [0013](0013-ideas-screen-trip-shopping-surface.md) | The Ideas screen is the trip-scoped shopping surface |
| [0014](0014-ai-model-access.md) | AI model access — tiered, on-device + BYO-key frontier, no server |
| [0015](0015-source-evaluations-and-taste-profile.md) | Source evaluations as a sibling record; a taste profile for prompts |
| [0016](0016-source-aware-capture-and-field-supplement.md) | Source-aware capture and on-demand field supplement |
| [0017](0017-context-aware-chat-window.md) | Context-aware chat window over the current screen |
| [0018](0018-ai-pool-stocking-discovery.md) | AI pool-stocking — the discovery pipeline |
| [0019](0019-mapkit-identity-capture-dedup.md) | MapKit identity on ideas — capture dedup and supplement |
| [0020](0020-capture-from-shared-location.md) | Capture from a shared location (Apple Maps, vCard) |
| [0021](0021-guide-link-enrichment-rung.md) | Guide-link enrichment rung — follow one recognized guide link |
| [0022](0022-in-app-browser-module.md) | GalavantWeb — an app-agnostic in-app browser module |
| [0023](0023-browser-rung-consumers.md) | Browser-driven consumers of GalavantWeb |
| [0024](0024-headless-rendered-dom-fetch.md) | Headless rendered-DOM fetch for automated enrichment |
| [0025](0025-persistent-browser-webpage.md) | Persistent in-app browser on `WebPage` + SwiftUI `WebView` |
| [0026](0026-idea-description-vs-notes.md) | Separate `description` (page fact) from `notes` (user space) |
| [0027](0027-galavantweb-lifted-to-webextractorkit.md) | GalavantWeb lifted to the shared `WebExtractorKit` package |
| [0028](0028-extension-cloudkit-sync-round-trip.md) | Share-extension → CloudKit sync round-trip + persisted-local gate |
| [0029](0029-structured-weekday-hours-and-start-day-solver.md) | Structured weekday hours on `Idea` + the start-day solver |
| [0030](0030-itinerary-aware-suggestions.md) | Itinerary-aware suggestions — context-scoped discovery, one-tap pull+schedule |
| [0031](0031-actionable-chat.md) | Actionable chat — turning a conversation into on-screen changes |
| [0032](0032-trip-header-image.md) | Trip header image — Unsplash "romance" via a hotlinked reference |
| [0033](0033-floating-untimed-stops.md) | Floating untimed stops — an "Anytime" stop holds a position, not a clock time |
| [0034](0034-calendar-reconciliation-authority.md) | The shared Apple Calendar is authoritative; Galavant ingests and reconciles |
| [0035](0035-itinerary-alternatives.md) | Itinerary alternatives — a ring of stops sharing one slot, exactly one active |
| [0036](0036-recommendation-handoff.md) | Recommendation handoff — candidate places from an external-LLM round-trip |
| [0037](0037-recommendation-evaluation-workspace.md) | Recommendation evaluation workspace — a candidate set processed like an inbox |
| [0038](0038-journey-today-projections-and-weather.md) | Journey & Today are read-only `TripPlan` projections; WeatherKit forecasts planned presence |
| [0039](0039-today-execution-completion-skip-defer.md) | Today becomes an execution surface — stop completion/skip/defer as reversible overlays on `TripIdea` |
