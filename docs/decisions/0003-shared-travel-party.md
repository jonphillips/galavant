# ADR-0003: One fully-shared travel-party library

*Status: accepted — 2026-06-10 (entity renamed Household → TravelParty 2026-06-12)*

## Decision

Everything — the idea pool, trips, tags, regions — is shared by default among the
members of a **travel party**. Both (or more) members read/write everything. There
is no private library and no per-record sharing UI.

The shareable graph is rooted at a single **`TravelParty`** record; every other
record descends from it (ADR-0007's single-FK tree). The product is used today by
one travel party of two (Jon + wife), but the model is N-person — the word and the
schema deliberately don't cap it at a couple.

## Why

For a small group planning travel together, "is this synced to her yet?" should
never be a question. One shared library is the simplest mental model and the
simplest CloudKit design. Per-trip CKShare granularity was considered and rejected
as complexity with no benefit at this scale.

**Naming (2026-06-12):** the root was first called `Household`, but that word
mentally caps the group at a cohabiting couple while the schema is already N-person
(Planners + per-planner IdeaInterests, not hardcoded his/hers). Renamed to
`TravelParty` — the travel-industry term for "the group traveling together," which
scales and sheds the couple/cohabitation connotation. "Crew" and "Party" were the
runners-up; bare "Party" is overloaded, "TripParty" wrongly implies per-trip
membership (the party persists across trips).

## The default travel party

There is one persistent default travel party, so a member never re-picks or
redefines it when capturing an idea or planning a new trip. It is **derived from
data, not stored per-device**: `TravelParty.ensureDefault(in:)` returns the single
shared party (creating it once, named "Our Travels"). A device-local default was
rejected — an empty second device would spawn a *new* party instead of joining the
shared one. The default is therefore just "the party your planner belongs to,"
which resolves identically on every member's device.

## Validation status (2026-06-12, M1)

- ✅ **Two-device sync, one account**: bidirectional, ~10s latency.
- ✅ **Share creation over the full graph**: `SyncEngine.share(record: travelParty)`
  succeeds and returns a real `icloud.com/share` URL; the `TravelParty` root carries
  its `Idea`s along as single-FK associations. This is the part the ADR was actually
  unsure about — SQLiteData *does* support everything-shared-with-one.
- ⏳ **Accept handshake**: deferred to real-device test (M5/TestFlight). The
  simulator can't drive it — `simctl openurl` routes a share link to the system
  `sharingd` daemon, which never hands `CKShare.Metadata` to the app's scene
  delegate. The accept code is verbatim from the pfw-sqlite-data template; it only
  runs when a human taps a real link on a real device. Low residual risk.

## Member visibility scoping (e.g. inviting the kids to plan one trip)

If a member joins a travel party, they see **everything** in it — that's the deal of
one shared library. Scoping what a given member sees:

- **Never** add a per-item `private`/`visibility` flag. In CloudKit, sharing is at
  the zone/share level, not per row — every record syncs to every participant's
  device. A flag could only *cosmetically hide* an idea in the UI while the data
  still sits on their phone. That is **false privacy**, worse than none, and it
  reverses this ADR's no-per-item-privacy line.
- The **only real** way to scope visibility is **multiple travel parties** (e.g. a
  couple party and a separate family party) — each is its own CloudKit share, truly
  separate data. The schema already supports it (TravelParty is a table; nothing is
  locked to one party). It is **additive, not a migration** — but real feature work
  (party switcher, per-party identity), so build it only when a concrete need
  appears, not speculatively.
- Near-term reality: kids usually don't need their own synced instance — they
  suggest, you enter. And a shared family pool is fine for most cases; the rare
  "hide it from them" need is better met by "don't put it in the shared pool" (or,
  later, a second party) than by a privacy feature.

## Consequences

- No per-item ownership/privacy semantics anywhere in the schema (no `mine` flags —
  V1/V2's `mine` column dies here). Authorship is attribution-only via `plannerID`.
- Conflict story can be simple last-writer-wins; members rarely edit the same field
  simultaneously.
