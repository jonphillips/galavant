# ADR-0043: Travel-mode overrides keyed by stable slot identity

*Status: accepted — 2026-08-18*

## Decision

Persist each trip-leg travel-mode override by the ordered pair of stable endpoint
identities, not by endpoint coordinates:

- an alternative-ring member uses `ring-<alternativeGroupID>`;
- an ordinary stop uses `stop-<TripIdea.ID>`;
- a lodging endpoint uses `stay-<TripStay.ID>`.

The coordinate `LegKey` remains the in-memory ETA cache key because MapKit needs
the active endpoints' real coordinates. The plan constructs both keys together so
an alternative swap can change coordinates without changing the logical slot.

Moving a stop carries an overridden outgoing leg's mode onto the moved stop's new
outgoing leg when its successor changes. Incoming legs and genuinely new legs use
their normal resolution rules.

## Migration

`TripTravelModeOverride` is CloudKit-synced, but a pure migration cannot reliably
resolve old coordinates back to current stops. The identity migration therefore
drops and recreates the override table with the clean identity schema. Existing
per-leg overrides reset once to the trip default; this is intentional and should
be called out before landing if the migration is vetoed.
