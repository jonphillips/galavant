# Evaluate workspace geographic model

*Status: Workstream 1 shipped (PR #93); workstreams 2 and 3 open, in order.*

*Summary: correct the Evaluate cockpit's geography — human-facing searches bias
instead of fence, unresolved candidates get a real display anchor, and the map
reuses `PlaceSelectionMap` for tap-to-resolve. Implements
[ADR-0045](../decisions/0045-evaluate-workspace-geographic-model.md).*

Read first: `Galavant/Trips/RecommendationWorkspaceView.swift` (the map + search +
Connect controls), `Galavant/Trips/RecommendationWorkspaceModel.swift` and
`RecommendationWorkspaceModel+Projection.swift` (the I/O shell + its delegation),
`GalavantLibrary/Sources/GalavantSchema/RecommendationWorkspaceProjection.swift`
(the pure read model, incl. `candidateMarkers` / `activeCandidateLocation` /
`fuzzyCoordinate`), `GalavantLibrary/Sources/GalavantPlaces/PlaceSearch.swift`
(`PlaceSearchScope` / `PlaceSearchClient` / `PlaceSearchModel`),
`GalavantLibrary/Sources/GalavantPlaces/PlaceMatcher.swift` (the Connect search),
`Galavant/MapPlaceSearchOverlay.swift`, and the surface we are converging onto,
`Galavant/PlaceSelectionMap.swift` (+ its use in `Galavant/Ideas/PoolMapView.swift`).

House rules: branch + PR to `main`, never push `main` directly. A new Swift file
must be declared in `project.yml`, then `xcodegen generate`, and **both**
`project.yml` and the regenerated `project.pbxproj` are committed together. Verify
with a build only — the reviewer runs on device; do **not** install/launch a
simulator:
`xcodebuild -scheme Galavant -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -skipMacroValidation build`
plus `swift test --package-path GalavantLibrary --filter <suite>` for schema/places
changes. (Heads-up: `swift test` aborts on this host for FoundationModels-linked
bundles; if a suite won't run, say so in the PR and lean on the app build.)

Land as a **stack of three small PRs** in order. Each is independently reviewable
and device-checkable, and workstream 1 restores the reported behavior on its own.

---

## 1. Human-facing search biases, never fences *(shipped — PR #93)*

The confirm-the-culprit fix. Landed on `fix/evaluate-search-scope`; full prompt
below for the record.

- `PlaceSearch.swift`: add `PlaceSearchScope.biasedRegions([MapRegion])`, handled
  like `.regions` but `required: false` (`regionPriority` stays `.default`). Leave
  the existing `.regions` (required) case untouched — the idea form and capture
  ladder depend on it. Give `PlaceSearchModel` a way to request biased scope and
  make `regionsChanged` preserve the biased-vs-required choice.
- `MapPlaceSearchOverlay.swift`: route **only** the workspace "search this map"
  field to biased scope (e.g. a `biased: Bool = false` param;
  `RecommendationWorkspaceView` passes `true`). `IdeaFormView` / `PoolMapView` /
  `TripCanvasMapView` callers are unaffected.
- `PlaceMatcher.swift`: in `recommendationSearch` (liveValue) use the biased scope
  instead of `.regions(regions)` so "Connect" biases rather than fences; keep the
  worldwide fallback when regions are empty.
- Do **not** touch `RecommendationCandidateSearch` — workstream 2 removes it.
- Tests: cover that `biasedRegions` yields `required: false` while `.regions` stays
  required.

Acceptance: on device, with candidate Lautersee active, typing "Mittenwald" returns
it and tapping Connect surfaces matches.

## 2. Candidate display anchors; retire `fuzzyCoordinate` *(after 1 lands)*

Give an unresolved candidate a real, non-authoritative coordinate for its map pin
and camera framing — and delete the phantom-coordinate machinery. **Model + pure
projection only; no `TripCandidate`/schema change** (the anchor is in-memory display
state, recomputed per session, never persisted, never written to an `Idea`).

- **Projection** (`RecommendationWorkspaceProjection.swift`): add a
  `candidateAnchors: [TripIdea.ID: Coordinate]` input (mirror how
  `resolveResultCoordinates` is already threaded). In `candidateMarkers`, use, in
  order: the resolved idea's coordinate → `candidateAnchors[candidate.id]` →
  nothing (no pin). `activeCandidateLocation` reads from the same markers, so it
  follows. **Delete `fuzzyCoordinate`.** `mapViewport` already unions
  `candidateMarkers`, so it frames correctly once anchors are real.
- **Model** (`RecommendationWorkspaceModel.swift`): add
  `private(set) var candidateAnchors: [TripIdea.ID: Coordinate] = [:]` and a
  best-effort `func loadCandidateAnchors() async` called from `task()` after
  `loadCandidateSet()`. For each candidate that is unresolved and lacks an anchor,
  run the biased recommendation search (`placeMatcher.matches(for:in: tripRegions)`)
  and take the first hit's coordinate as the anchor. Keep it cancellable and off the
  render path; a failed geocode leaves no anchor (no pin). Feed `candidateAnchors`
  into the projection via `RecommendationWorkspaceModel+Projection.swift`.
- **Retire the locality-box selector**: delete
  `GalavantSchema/RecommendationCandidateSearch.swift` and its tests, and simplify
  `candidateSearchRegions` in `+Projection.swift` — after workstream 1 the field
  just biases to `tripRegions` directly, so the synthesized box is dead. Update the
  `MapPlaceSearchOverlay` call site accordingly.
- Tests: extend `RecommendationWorkspaceProjectionTests` (or equivalent) to feed
  `candidateAnchors` fixtures and assert `candidateMarkers` /
  `activeCandidateLocation` / `mapViewport`; assert an anchorless unresolved
  candidate yields no marker. Delete `RecommendationCandidateSearchTests`.

Acceptance: on device, opening a set draws grey pins for unresolved candidates at
their real rough locations; switching candidates frames to the active pin.

## 3. Evaluate map reuses `PlaceSelectionMap` (tap-a-POI → resolve) *(after 2 lands)*

Replace the bespoke `Map(position:)` in `RecommendationWorkspaceMap`
(`RecommendationWorkspaceView.swift`) with `PlaceSelectionMap`, `.immediate` policy,
so a native Apple Maps POI tap resolves the active candidate.

- Move the itinerary/stay/candidate/resolve-result markers into the
  `@MapContentBuilder mapContent` closure (keep the active-candidate ringed pin and
  the resolve-result purple pins).
- Wire `onSelectPlace: { place in model.resolveResultTapped(place) }` so tapping a
  POI runs the same resolve+reconcile path Connect's result rows use.
- Keep the `MapPlaceSearchOverlay` (now biased) and the `ActiveCandidateResolveControls`
  ("Connect") overlays. Preserve the existing "frame once on load, then don't yank
  the camera" behavior (`didInitialFrame`, the pan-to-include-active-pin logic).
- No projection or model change beyond what workstream 2 established.

Acceptance: on iPad **and** iPhone, tapping a visible POI resolves the active
candidate; the search field, Connect, and candidate pins all still work and coexist
with the native selection. Device check required (per ADR-0044, compile cannot prove
coexistence).

---

### Appendix — workstream 1 prompt (as dispatched)

> Branch off main as `fix/evaluate-search-scope`; land via PR (never push main).
> In the Evaluate workspace the "Search this map" field and "Connect" button return
> nothing for a place plainly on screen because PR #90 rescoped these human-facing
> searches to trip regions with `regionPriority = .required` (a hard fence). Add
> `PlaceSearchScope.biasedRegions` (like `.regions` but `required: false`), route the
> workspace search field and `PlaceMatcher.recommendationSearch` to it, and leave
> `.regions` (required) — used by the idea form and capture ladder — untouched. Do
> not remove `RecommendationCandidateSearch`. Build with `-skipMacroValidation`;
> keep the PR isolated so Jon can device-confirm that "Mittenwald" and Connect
> resolve.
