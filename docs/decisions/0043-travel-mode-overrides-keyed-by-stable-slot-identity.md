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

These overrides are intentionally **local-only**. `TripTravelModeOverride` is not
registered in `GalavantCloudSync`'s `SyncEngine` table list, so a mode choice belongs
to the device's planning surface rather than being a shared trip fact. Adding it to
CloudKit later would be a separate product decision; stable identities make that
future change viable, but do not make it implicit.

Moving a stop carries an overridden outgoing leg's mode onto the moved stop's new
outgoing leg when its successor changes. Incoming legs and genuinely new legs use
their normal resolution rules.

## Migration

Because the table is local-only, the identity migration safely drops and recreates
the local override table. Existing per-leg overrides reset once to the trip default
on each device; there are no CloudKit records, cross-device schema concerns, or
migration veto required for sync compatibility.

Old identity rows are not eagerly garbage-collected when stops or alternatives are
removed. They are ignored because resolution only consults identities present in the
current plan; a future local cleanup pass can remove rows no longer referenced.
