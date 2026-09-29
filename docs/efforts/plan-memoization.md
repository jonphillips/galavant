# Handoff — memoized trip-plan read model

**Status:** Phase 1 implemented on a standalone branch; caching is optional pending device evidence  
**Summary:** Land the pure one-pass travel graph first, then decide independently whether the remaining model-level construction cost warrants an observation-backed snapshot.  
**Related:** [CURRENT_HANDOFF](../CURRENT_HANDOFF.md#pending-pr--stable-travel-mode-overrides), [ADR-0038](../decisions/0038-journey-today-projections-and-weather.md), [`TripPlan`](../../GalavantLibrary/Sources/GalavantSchema/TripPlan.swift), [`TripPlanningModel`](../../Galavant/Trips/TripPlanningModel.swift)

## Measurement first

Temporary counters wrapped `TripPlan` construction, `effectiveResolvedStops`,
`resolvedAlternativeRings`, and `itinerary`. A temporary schema test exercised the
existing large-itinerary fixture: 40 days × 6 located stops/day = 240 stops. The test
also reproduced the model getter's filtering and `ideasByID` dictionary construction.
The 100-construction sample only stabilized the per-access timing; it is not a product
constant. All instrumentation and the temporary test were removed after capture.

| Operation | Debug | Optimized | What happened |
| --- | ---: | ---: | --- |
| 100 getter-shaped constructions | 38.79 ms | 11.94 ms | 0.388 / 0.119 ms per access; `TripPlan.init` itself was 0.127 / 0.033 ms per access |
| One `itinerary` | 5.86 ms | 0.98 ms | One `effectiveResolvedStops` and itinerary derivation |
| One `legModes` | 915.06 ms | 109.83 ms | `itinerary` and `effectiveResolvedStops` each ran **161 times** |
| Six representative `model.plan` accesses | 911.04 ms | 111.38 ms | Six constructions, but 162 itinerary derivations because one access asked for `legModes` |
| 240 ordinary-row `alternatives(forStop:)` accesses | 102.93 ms | 28.03 ms | 240 constructions; ordinary stops return before ring derivation |

The pre-instrumentation targeted regression test completed in 1.760 seconds in Debug,
consistent with the instrumented finding once fixture setup and assertions are included.

This is not cheap enough to stop. It also falsifies the narrow premise that memoizing
only the model getter fixes the hazard: in an optimized build, getter-shaped construction
is about 0.12 ms/access, while the travel graph spends about 106 ms rebuilding `itinerary`
161 times. The model cache still matters — row-scoped accesses alone cost 28 ms in this
fixture — but most of the measured stall is a pure-core repeated-work bug.

These are macOS SwiftPM measurements, not an iPhone trace. The task forbids launching a
simulator, and `TripPlanningModel` executes only in the iOS app/test host, so no claim is
made about device wall time. The call counts are platform-independent and identify the
same algorithmic work reported in the device backtrace.

The standalone Phase 1 regression now completes in 0.016 seconds in Debug and asserts
that the batch graph derives `itinerary` exactly once and resolved stays exactly once.

## Sequencing decision

The pure travel-graph correction lands as its own first commit and PR, with no cache,
database request, or model changes. It is independently testable and captures nearly all
of the measured win. Device dogfood then decides whether the remaining 28 ms synthetic
row-access cost is visible enough to justify Phase 2.

Caching is therefore optional and deferrable, not part of the travel-graph fix's done
criteria. If Phase 1 makes the large trip responsive on device, Phase 2 needs fresh
evidence before implementation.

## Optional Phase 2 design: observation-backed snapshot

### Cache location

Keep `TripPlan` an ordinary `Equatable & Sendable` value. Add a `TripPlanRequest` in
`GalavantSchema` that conforms to SQLiteData's `FetchKeyRequest` and returns one complete
`TripPlan` from a single database read transaction. `TripPlanningModel` holds the last
result with `@ObservationIgnored @Fetch` and exposes that wrapped value as `plan`.

This is model-level memoization using the database observation's stored value, not a lazy
reference cache hidden inside `TripPlan`. It preserves the functional-core / observable-
shell boundary and makes the request testable with the package's in-memory database.

Do not add mutable lazy storage to `TripPlan`. A reference box would complicate
`Equatable`, `Sendable`, copying, and mutation semantics; hand-written lazy fields would
also become stale because `TripPlan` currently exposes mutable input properties. Making
the whole type immutable and eagerly materializing every projection is possible, but the
measurement does not justify that surgery yet.

### Invalidation signal

Use SQLiteData/GRDB's value-observation invalidation for `TripPlanRequest`. There is no
invented hash, count tuple, timestamp, or revision column. The request reads the current
trip and the eight tables that feed the plan (`Trip`, `TripIdea`, `Idea`, `TripStay`,
`TripDayRegion`, `MapRegion`, `CalendarTripConstraint`, and `TripAlternativeGroup`); a
relevant database change reruns the request and replaces the wrapped snapshot.

This is cheaper and safer than deriving a cache key from the `@FetchAll` arrays. Counts
and endpoint IDs miss in-place edits, while a complete structural key/equality pass is
O(all fetched rows) and approaches the work the cache is intended to avoid.

The V1 request can preserve current semantics by fetching the same row sets, merely once
per observed database change rather than once per property access. Scoping the idea and
region lookups to referenced IDs is a follow-up optimization only if profiling earns it.

This request is additive read-only infrastructure, not a schema migration and not a
rewrite of `TripPlanningModel`'s existing fetches. The existing `@FetchAll` arrays remain
in place for Ideas/Add, lens, and editor behavior. SQLiteData shares identical fetch keys,
not overlapping table reads, so the composite request creates a distinct GRDB observation
beside those arrays. The expected cost is duplicate reads/materialization and extra view
invalidations after a write, especially if `Idea` and `MapRegion` remain table-wide; it
does not change sync or persistence semantics.

### Observation-driven view invalidation

`@Fetch` is marked `@ObservationIgnored` only to avoid `@Observable` macro expansion over
the property wrapper. Its underlying `SharedReader` still participates in observation,
which is the established SQLiteData model pattern. A view that reads `model.plan` reads
the `@Fetch` wrapped value; when the request publishes a replacement, SwiftUI invalidates
the view and the next body pass receives the new snapshot.

There is no atomic ordering between this composite observation and the existing raw-array
observations. A SwiftUI body can briefly combine plan N with raw arrays N+1, or the reverse;
GRDB may run the observations concurrently and SwiftUI coalescing is not a consistency
barrier. Current itinerary code co-reads `model.plan` and raw-observed `model.trip`, so a
trip date/length change is a concrete one-frame mismatch case. This is accepted as a
transient, self-healing cosmetic window unless device dogfood proves otherwise; no action
should depend on the two observation streams being same-revision.

The package regression should prove the full contract: load a request, assert its derived
products, write a changed input through the in-memory database, await the observation,
and assert that the new plan reflects it. Separate pure tests compare itinerary,
shortlist, scheduled stops, rings, and leg identities before and after the refactor.

Also test eventual convergence between the plan snapshot and representative raw
projections after trip, stop, idea, stay, and region writes. Do not write a flaky
"never mixed" assertion because this design does not provide that guarantee. If strict
same-frame coherence becomes necessary, have the request return the fetched `Trip`
alongside `TripPlan` and make itinerary/map consume both overlapping facts from that one
snapshot while leaving Add/lens/editor arrays intact.

## Phase 1: pure-core correction

Refactor `TripPlan.allLegPairs` to obtain `itinerary` and resolved stays once, then thread
each day's already-resolved stops/stays through the leg helper functions. Today it obtains
`itinerary` once for the outer day list and again in four helper families for every day,
which produces `1 + 4 × days` derivations — 161 for the measured 40-day fixture.

This keeps the win in the tested pure core without adding caches. Public per-day helpers
can retain their behavior; the batch graph used by `legModes`, `legIdentities`, and
`allLegs` gets one-pass internals. The existing large-itinerary regression becomes a
tighter call/result guard rather than a one-minute wall-clock net.

## Alternative: cache the existing arrays with manual Observation invalidation

An `@ObservationIgnored` cached `TripPlan` could be built inside
`withObservationTracking`, with an observable generation incremented by the `onChange`
callback. Every `plan` access would read the generation, cache hits would avoid all input
work, and a fetch change would clear the cache and invalidate views.

This avoids a second database observation and guarantees the plan is assembled from the
same array snapshots the rest of `TripPlanningModel` uses. It is also substantially more
subtle: the one-shot tracking callback must be re-armed after every rebuild, actor hopping
must not expose a stale cache window, and its real invalidation behavior can only be tested
in the iOS app test host. Given the compile-only constraint here, I do not recommend
landing that mechanism without Jon explicitly preferring the smaller runtime footprint
over the clearer `@Fetch` contract.

## Phase 2 decision gate

If device evidence still warrants caching after Phase 1, the recommendation remains the
`TripPlanRequest` / `@Fetch` snapshot. Its cost is one additional database observation
beside the model's existing raw fetches plus the accepted cosmetic consistency window.
Its benefit is that invalidation is owned by the persistence mechanism, package-testable,
and impossible to bypass with an incomplete hand-built key.

The manual Observation cache is fewer database reads and a smaller immediate diff, but it
has a more fragile correctness story. The later choice remains:

1. **Recommended if caching is earned:** observation-backed `TripPlanRequest` snapshot.
2. **Alternative:** manual model cache + observed generation.

No ADR is warranted for either: both implement the existing functional-core / observable-
shell decision and change no product, schema, or sync semantics. An ADR would only become
appropriate if the scope expands to making `TripPlan` an immutable, eagerly materialized
snapshot type across the codebase.
