# ADR-0045: Evaluate workspace geographic model

*Status: accepted — 2026-08-22*

*Amends [ADR-0037](0037-recommendation-evaluation-workspace.md) (recommendation
evaluation workspace) and corrects the region-fencing behavior shipped in PR #90
("Fix Evaluate workspace browser crash and dead map search"). Retires the
`fuzzyCoordinate` region-name-match and the `RecommendationCandidateSearch`
locality-box selector. Reuses `PlaceSelectionMap` from
[ADR-0044](0044-ideas-map-explore-then-capture.md).*

## Context

Field use of the Evaluate cockpit surfaced three coupled defects, all rooted in how
the workspace reasons about a candidate's *geography*:

1. **"Search this map" returns nothing for a place plainly on screen.** PR #90
   rescoped the field from a viewport bias to the trip's regions searched with
   `regionPriority = .required` — a hard fence. When the trip's saved regions do
   not tightly enclose the typed place (e.g. ADR-0013 subregion boxes), MapKit
   returns nothing even though the place is centered in the viewport. A field
   labeled "Search this map" stopped searching the map.

2. **"Connect" silently does nothing.** The button runs the same region-`.required`
   search (`PlaceMatcher.recommendationSearch`). When the fence excludes the place,
   `resolveResults` stays empty and the button looks dead.

3. **Unresolved candidates rarely appear on the map at all.** `TripCandidate`
   carries a `locality` *string* and a `searchHint`, never a coordinate. The only
   pin an unresolved candidate could get came from `fuzzyCoordinate`, which
   name-matches the locality string against a saved trip region and borrows that
   region's centroid — usually `nil`, and when non-nil, a coarse point (a region
   like "Bavaria" ≈ Munich) far from the actual place. So the map could not do its
   one job — "does this candidate make geographic sense" — for the very candidates
   under review, and the doc comments describing a "box around the candidate's LLM
   locality point" referred to a coordinate the type never held.

These are one problem: the workspace treated a hard region fence as a safety
contract and leaned on a phantom coordinate to place things. The fix is to make the
human-facing searches *bias* rather than *fence*, and to give a candidate a real —
but explicitly non-authoritative — coordinate for display.

## Decision

One geographic model for the workspace, in three parts.

1. **Human-facing place search biases toward geography; it never fences.** A search
   field or button the user is watching (the workspace "Search this map" field and
   the "Connect" button) uses a new biased-regions scope: MapKit's
   `regionPriority = .default` around the trip's regions, so a clearly-named place
   just outside them still surfaces. `regionPriority = .required` remains **only**
   on the unattended paths where a hard geographic contract is correct — the
   capture ladder and the idea form's location search — never on an interactive
   field.

2. **An unresolved candidate carries a non-authoritative *display anchor*.** On
   workspace load the model geocodes each still-unresolved candidate once, reusing
   the same biased recommendation search "Connect" uses, and holds the best hit's
   coordinate as in-memory display state keyed by the candidate's stop id. The
   anchor is fed into the pure projection alongside the existing resolve-result
   coordinates; the projection draws the candidate's grey pin and frames the camera
   from it. The anchor is **display and camera state only** — it is never persisted,
   never written to an `Idea`, and never auto-resolves the candidate. Resolution
   still requires a human to pick a `Place` and confirm (ADR-0037 boundary intact);
   the anchor merely shows roughly where the candidate is while that decision is
   pending. Geocoding is best-effort and cancellable; a candidate that fails to
   geocode simply has no pin, which is honest.

3. **The workspace map reuses the shared `PlaceSelectionMap`.** The bespoke
   `Map(position:)` in `RecommendationWorkspaceMap` — which has no selection binding,
   so native POI taps are inert — is replaced by `PlaceSelectionMap` with the
   `.immediate` policy. Tapping an Apple Maps POI resolves it to a `Place` and hands
   it to the existing `resolveResultTapped`, so "tap the pin, Connect" is a single
   gesture. The itinerary, stay, and candidate markers move into the map's
   `mapContent`; the search overlay and Connect controls remain.

Retired by this decision: `RecommendationWorkspaceProjection.fuzzyCoordinate` and
the `RecommendationCandidateSearch` locality-box selector (with its tests). After
part 1, the search field biases to the trip's regions directly and no longer needs a
synthesized locality box; after part 2, pins come from real anchors.

## Consequences

- **`PlaceSearchScope` gains a biased-regions case**; the existing `.regions`
  (required) case is unchanged, so the idea form and capture ladder keep their hard
  geographic contract. Only the two interactive Evaluate paths move to biased.
- **The model gains a geocoding step** at load. It is best-effort and off the
  render path; candidate pins pop in asynchronously and the anchor is recomputed per
  session rather than stored. `PlaceMatcher`/`PlaceSearchClient` remain the only
  MapKit boundary, so the step is testable with fixtures.
- **The projection stays pure.** Candidate anchors are an input value (like
  `resolveResultCoordinates`), so `candidateMarkers`, `activeCandidateLocation`, and
  `mapViewport` are exercised as value types; deleting `fuzzyCoordinate` removes the
  projection's only implicit dependency on region names.
- **One map surface, not two.** Converging on `PlaceSelectionMap` collects the
  ADR-0044 dividend: the Evaluate map gains native POI detail/tap behavior for free
  and sheds bespoke marker/camera code. Tap-to-resolve on iPad and iPhone needs a
  real device check — compile verification cannot establish that the POI selection
  and Connect controls coexist.
- **The ADR-0037 no-auto-resolve boundary is unchanged.** The anchor and the map POI
  detail are exploration only; a durable place is still created solely by a human
  confirmation.
- **Sequencing matters.** Part 1 is a contained, independently shippable fix (it
  restores the reported behavior on its own); parts 2 and 3 land on top of it. The
  execution stack is in `docs/handoff/evaluate-geographic-model.md`.
