# Codex task: keep per-leg travel modes stable across alternative swaps and stop moves

## Problem

A user-chosen travel mode for an itinerary leg reverts to the trip default whenever
the user selects a different alternative in a multi-option stop, or moves a stop.

Root cause: a `TripTravelModeOverride` is keyed by the **absolute coordinates** of
both endpoints (`fromLat/fromLon/toLat/toLon`, matching `LegKey`), and
`effectiveMode(for:)` looks it up by that coordinate `LegKey`
(`Galavant/Trips/TripPlanningModel+Directions.swift`). So:

- **Select an alternative:** the slot stays but the endpoint coordinate moves
  (B1 → B2). The stored key `(A→B1)` no longer matches the new leg `(A→B2)` → default.
- **Move a stop:** the legs touching it are replaced by different-endpoint legs → no
  key matches.

## Goal (approved design)

**Re-key travel-mode overrides by stable slot identity instead of coordinates**, and
**carry a moved stop's outgoing mode onto its new outgoing leg**.

- A leg's identity is the ordered pair of its endpoints' **stable identity strings**:
  - a stop that belongs to an alternatives ring → `"ring-<alternativeGroupID>"`
    (so every alternative in the slot shares one identity — this is the core fix);
  - a plain stop (no ring) → `"stop-<TripIdea.ID>"`;
  - a lodging base endpoint → `"stay-<TripStay.ID>"`.
  (These mirror the existing `TravelEndpoint.id` convention in
  `TravelConnector.swift`, except a ring member uses its **group**, not the active
  member's id.)
- Overrides persist against this identity pair; the **ETA cache** (`travelTimes`,
  in-memory, keyed by coordinate `LegKey`) stays coordinate-keyed — MKDirections needs
  real coordinates. Only the override's identity changes.

### Behavior after the change

- Selecting a different alternative keeps the leg's chosen mode (slot identity
  unchanged). ✓
- Reordering such that a leg's two endpoints and adjacency are unchanged keeps its
  mode (already true today; stays true). ✓
- Moving a stop to a new position: its **outgoing** leg mode is carried onto its new
  outgoing leg (the approved heuristic). Legs that are otherwise genuinely new get the
  trip default.

Accepted caveat (intended): a mode persisting across a swap means an "across town"
alternative inherits the previous walkable choice until re-changed. That is the
desired behavior; the user can re-tap.

## Repo conventions (must follow)

- Read `AGENTS.md` + `CLAUDE.md` first. Point-Free style, no TCA, value types,
  make-impossible-states-unrepresentable, `@Dependency` not singletons, **no version
  suffixes in any identifier (ADR-0006)**.
- **XcodeGen**: `project.yml` is source of truth; no new files/targets expected, but if
  you add any, `xcodegen generate` and commit both `project.yml` and `project.pbxproj`.
- **Branch + PR**: never push to `main`. Work on `feat/stable-travel-modes` and land via
  PR.
- **Verification = compile + unit tests only** (no simulator/device; Jon reviews on his
  device). `swift test` aborts here when FoundationModels-linked test targets are
  present — run the `GalavantSchema` tests the documented way (temporarily disabling FM
  test targets if needed). App builds with `-skipMacroValidation`.
- Keep all pure logic in the `GalavantSchema` functional core so it's testable without a
  DB or `@Observable` (the app target is effectively untestable — "watch for fat
  models").

## MIGRATION DECISION (flag for Jon in the PR description)

`TripTravelModeOverride` is CloudKit-synced. Migrating existing **coordinate** rows to
identity rows would require resolving coords→stop at migration time, which the pure
migration can't do cleanly. Recommended: a new migration that **recreates the
`tripTravelModeOverrides` table with the identity schema, dropping existing rows** —
i.e. existing leg-mode overrides reset once to the trip default. This is low-stakes
(modes re-derive from the trip default; a few taps to restore the ones that matter).
Implement that, and call it out explicitly in the PR description so Jon can veto. Do
**not** keep dead coordinate columns alongside identity columns "just in case" — keep
the record clean.

## Implementation

### 1. Stable endpoint identity — `GalavantSchema`

Add a small pure API to compute an endpoint's stable identity string:

- For a `ResolvedStop`: `"ring-\(groupID)"` when `entry.alternativeGroupID != nil`,
  else `"stop-\(entry.id)"`.
- For a `ResolvedStay`: `"stay-\(stay.id)"`.

Introduce a value type for a leg's identity, e.g.:

```swift
public struct LegIdentity: Hashable, Sendable {
  public var from: String   // stable endpoint id
  public var to: String
}
```

### 2. Plan exposes leg identities — `TripPlan+Travel.swift`

Thread `LegIdentity` alongside the existing coordinate `LegKey` through leg
construction so the plan can answer "what is the stable identity of this coordinate
leg?":

- Extend `legs(forDay:)`, `baseLegs(forDay:)`, `returnLegs(forDay:)`,
  `stayTransferLegs(forDay:)` (and the private `lodgingToStopRoute` /
  `stopToLodgingRoute` / `stayTransfer` route helpers) to also produce the endpoints'
  stable identities. Capture identity **at construction** (where the `ResolvedStop` /
  `ResolvedStay` is in hand) — do not reverse-map coordinates back to stops afterward.
- Expose `public var legIdentities: [LegKey: LegIdentity]` (built in parallel with
  `allLegs`, uniquing on the coordinate key), plus a convenience
  `public func legIdentity(for leg: LegKey) -> LegIdentity?`.

### 3. Persistence — `TripTravelModeOverride.swift` + `Database.swift`

- Change `TripTravelModeOverride` to store the identity pair
  (`fromEndpointID: String`, `toEndpointID: String`, `transportMode: String`) instead
  of the four coordinate columns. Update its init/accessors to work in `LegIdentity`
  space; update `setMode` to key/delete by `(tripID, fromEndpointID, toEndpointID)`
  (still one synced row per `(trip, legIdentity)`).
- `Database.swift`: register a **new** migration that recreates the
  `tripTravelModeOverrides` table with the identity schema (drop + create + index on
  `tripID`), per the MIGRATION DECISION above. Do not edit the original migration.

### 4. Resolution — `Galavant/Trips/TripPlanningModel+Directions.swift`

- `persistedModeOverrides` becomes `[LegIdentity: TransportMode]` (built from the
  identity-keyed DB rows).
- Keep an in-memory optimistic cache in the same identity space.
- `effectiveMode(for leg: LegKey)`: resolve `identity = plan.legIdentity(for: leg)`,
  then apply the existing precedence — in-memory override → persisted override → trip
  default (`trip?.mainTransportationMode`) → auto-detect (walking ≥ threshold →
  transit). If a leg has no resolvable identity (shouldn't happen for located legs),
  fall through to the default path.
- `setMode(_:for leg:)`: resolve the leg's `LegIdentity` via the plan and persist by
  identity. `fetchMissingETAs` still fetches by coordinate `LegKey` (unchanged) but
  chooses the mode via the identity-resolved override.

### 5. Move heuristic (carry outgoing) — pure helper + model write paths

Make it testable: add a **pure** function in `GalavantSchema`, e.g.

```swift
// Given the moved stop's stable id, the override map, and the before/after leg
// identity sets, return the override writes that carry the moved stop's OUTGOING
// leg mode onto its new outgoing leg. Returns nothing when the old outgoing leg had
// no override or the successor is unchanged.
static func carryOutgoingOnMove(
  movedEndpointID: String,
  overrides: [LegIdentity: TransportMode],
  beforeLegs: [LegIdentity],
  afterLegs: [LegIdentity]
) -> [(leg: LegIdentity, mode: TransportMode)]
```

Wire it into the model move paths — `moveToDay(_:day:)` and the intra-day reorder
(`moveStopEarlier` / `moveStopLater` → `reorderDay`) in
`Galavant/Trips/TripPlanningModel+Scheduling.swift`: capture `plan.legIdentities`
before the reorder write, perform the write, recompute `plan.legIdentities`, then apply
`carryOutgoingOnMove` and persist any returned writes via `TripTravelModeOverride`.
"Outgoing" = the leg whose `from` equals the moved stop's stable id.

### 6. Tests — `GalavantLibrary/Tests/GalavantSchemaTests/`

- **Leg identity stability:** a ring's leg identity is unchanged after
  `setActiveAlternative` switches the active member (the pre/post `legIdentities` for
  the slot's incoming/outgoing legs match). Add near the alternatives/travel tests.
- **Override resolution:** an identity-keyed override resolves for the active member
  and still resolves after the swap; a plain-stop override keys by `stop-<id>`; a
  lodging leg keys by `stay-<id>`.
- **carryOutgoingOnMove:** returns the carried write when the moved stop had an
  outgoing override and its successor changed; returns empty when there was no override
  or the successor is unchanged.
- Adjust any existing travel-mode/override tests that assumed coordinate keying.

### 7. Docs

- Add a short decision note under `docs/decisions/` (next ADR number) — "travel-mode
  overrides keyed by stable slot identity" — recording the identity rule, the ETA-cache
  stays coordinate-keyed, the migration reset, and the carry-outgoing move heuristic.
- One line in `docs/DONE_LOG.md`; update `docs/CURRENT_HANDOFF.md` if tracked there.

## Acceptance

- App builds (`-skipMacroValidation`); `GalavantSchema` tests pass.
- Setting a leg mode, then selecting a different alternative in that slot: the mode
  persists (both the timeline connector row and the ETA reflect the chosen mode).
- Moving a stop carries its outgoing-leg mode to its new outgoing leg; unrelated legs
  keep their modes; genuinely new legs take the trip default.
- New identity-keyed overrides round-trip through create/edit and sync (nullable/clean
  schema); migration recreates the table without crashing on existing data.
- Landed on `feat/stable-travel-modes` via PR, with the migration-reset decision called
  out in the PR description.
