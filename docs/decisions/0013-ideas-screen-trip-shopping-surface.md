# ADR-0013: The Ideas screen is the trip-scoped *shopping* surface — capsule → subregions → map, with one lens shared across trip / browse / day

*Status: accepted — 2026-06-22*

## Context

Browsing *unselected* ideas from the itinerary screen isn't feasible — the itinerary
is a per-day timeline, not a pool browser. And the Ideas list has always felt like a
cavern, especially on iPad. Yet the Ideas screen already has most of the machinery to
be the place you *shop* for a trip:

- a list/map toggle and `PoolMapView` (pins for located ideas);
- an active-trip **capsule bar** ("All" + a pill per in-play trip) that scopes the
  pool to the trip's regions and turns each row into a pull/shortlist control;
- `scopeRegions` (the trip's region union as the lens) and `activeTripIdeaIDs` (the
  set already pulled onto the trip) — the model already knows both.

What's missing is the ability to *steer* that browse: narrow to specific sub-regions
of a multi-region trip (Provence vs. the Loire vs. Normandy), and *see* on the map
which pins are already on the trip vs. still candidates.

This also clarifies a pattern that had grown up piecemeal. A `MapRegion` is used as a
**lens** at three scopes, all over the same saved regions:

1. **Trip** (`TripRegion`, ADR-0004) — the geography a trip is about.
2. **Browse** (this ADR) — what I'm shopping for *right now*.
3. **Day** (`TripDayRegion`, ADR-0012) — what a given day is anchored in.

## Decision

**The Ideas screen is the trip-scoped shopping surface. Selecting a trip capsule
reveals its regions as toggleable subregion chips; the list and map constrain to the
toggled lens; the map distinguishes already-pulled ideas from candidates. The
itinerary stays the scheduling surface.**

1. **Subregion chips (A).** When a trip capsule is active and the trip has **2+
   regions**, a chip row under the capsule bar shows the trip's regions as an
   *opt-in narrowing* multi-select. **None selected = the trip's full region union**
   (today's behavior — not "show nothing"); toggling some narrows `scopeRegions` to
   that subset. Selecting a different capsule resets the toggles.
2. **Map: pulled vs. candidate, binary (B).** `PoolMapView` tints ideas already on
   the active trip distinctly from candidates. **Binary on-trip / candidate only** —
   not per-status (considering/shortlisted/scheduled) colors: "I'll never remember
   the colors." The existing visited tint stays for the "All" pool.
3. **Map frames to the toggled lens (C).** The pool map frames to the union of the
   toggled subregions (or the trip's full union when none) rather than auto-fitting
   pins, via a shared `MapRegion.boundingBox(of:)` (the same union math the canvas's
   trip-region fallback uses).
4. **iPad: list + map side-by-side (D).** On regular width the Ideas screen shows the
   list and the map *together*, not a segmented swap — Jon is visual and always wants
   the pins in view while browsing. iPhone (compact) keeps the list/map toggle.

### This redefines ADR-0012 slice B

ADR-0012 deferred a per-day idea filter in the itinerary's Add flow. With this ADR,
that filter *is* this surface: "Add to day" should **open the Ideas screen scoped to
the trip with the day's region pre-toggled**, rather than reimplement a cramped pool
browser inside the timeline. Slice B becomes a navigation hand-off, not a new filter.

## Alternatives

| Option | Verdict |
| --- | --- |
| **Trip shopping on the Ideas screen (chosen)** | Reuses the capsule + lens + map already there; one lens model across three scopes; keeps the itinerary lean. |
| **Build a pool browser into the itinerary Add flow** | Rejected — duplicates the pool/map/lens in a worse space; the itinerary is a timeline, not a browser. The cross-screen hand-off is simpler and richer. |
| **Per-status pin colors** | Rejected now (memorability). Binary on-trip/candidate; revisit if a richer read is wanted. |
| **iPad: keep the list/map toggle** | Rejected — the side-by-side is the actual cavern fix and matches how Jon works. |

## "None selected" semantics (the one ambiguity, resolved)

Subregion chips are an **additive narrowing**, so the empty state is meaningful: no
chips on = browse the whole trip (union of all its regions, plus any pulled ideas
that sit outside every region — the capture-onto-trip case `activeTripIdeaIDs` already
pins). This makes "no subregions selected" a sensible *default*, not a dead end.

## Relationship to prior decisions

- **ADR-0004 (regions as the pull lens):** this is that lens made *steerable* per
  browse, and unified with the trip/day scopes.
- **ADR-0012 (per-day region):** same `MapRegion` data; slice B becomes the
  Add-to-day → scoped-Ideas hand-off described above.

## Consequences

- **Model:** `selectedSubregionIDs` + `tripSubregions` + `toggleSubregion`;
  `scopeRegions` honors the toggled subset; reset on capsule change; expose the
  pulled-id set and the framing regions to the view.
- **Schema/core:** `MapRegion.boundingBox(of:)` (pure, tested) for union framing.
  No new tables — region-as-lens is computed, not stored, at the browse scope.
- **Views:** subregion chip row in `IdeasScreen`; `PoolMapView` gains a pulled-id set
  and a `[MapRegion]` framing input; iPad regular-width side-by-side layout.
- **Deferred:** distance context when selecting a pool pin (how far is this from the
  trip's other stops / the day's base) — a natural future enhancement, not this slice.
- **Retires:** ADR-0012 slice B as a standalone filter (folded into the hand-off).
