# ADR-0008: Second-device identity and sync-duplicate hardening

*Status: accepted — 2026-06-12. Raised by an external Codex audit; both items
are "what happens when the second device arrives" gaps in the M2a flow.*

## Problem 1: first-run can create duplicate planners / a stray party

M2a's first-run flow creates a new `Planner` (attached to
`TravelParty.ensureDefault`) whenever the device-local `currentPlannerID` is
empty. Two failure cases:

1. **Spouse's device, fresh install:** if she launches the app *before*
   accepting the share, `ensureDefault` creates a brand-new local party and a
   planner attached to it. After accepting the share, her database holds two
   parties, and her planner hangs off the wrong one.
2. **Same person, new/reinstalled device:** `currentPlannerID` is empty (it is
   device-local by design), so the flow creates a *duplicate* "Jon" planner
   instead of binding to the existing synced one.

## Decision

First-run becomes **bind-or-create against synced planners**:

- The name-capture step is deferred until the database has settled (or the
  share has been accepted). If synced `Planner` rows exist, show
  **"Who are you?" — pick an existing planner or create a new one.** Picking
  sets only the device-local `currentPlannerID`.
- "This device is me" never syncs; it stays in `@Shared(.appStorage)`
  (ADR-0007 already requires this).
- `Planner.create` always attaches to the party resolved *after* share
  acceptance, never to a freshly spawned local one. If an empty stray party
  exists alongside an accepted shared one, prefer the shared party (the one
  with members/content) and clean up the empty stray.

Implementation slated for the M2 tail (before any second-device usage).

## Problem 2: sync can create duplicate IdeaInterest rows

`IdeaInterest.set` enforces one row per `(ideaID, plannerID)` in code, but two
devices editing offline can each insert a row that syncs into a duplicate pair.

A database unique index is **not an option**: SQLiteData's CloudKit sync
explicitly does not support unique indexes other than primary keys (per the
pfw-sqlite-data iCloud documentation). So:

- Keep the code-level upsert as the only writer.
- Add a **dedup-on-read rule**: queries that surface interests pick one row
  per (idea, planner) deterministically (e.g. lowest rowid/UUID wins), and a
  cleanup pass deletes the losers when detected.
- Test with deliberately seeded duplicates.

## Future: back planner identity with the CloudKit participant (Apple ID)

The current "Who are you? / type a name" flow is a **placeholder** for the
identity CloudKit already has. The durable model (post-M5, once the real-device
share-accept flow exists):

- Each `Planner` is keyed to a **CloudKit share participant** (the person's
  Apple ID — globally unique, the real strong key). This makes the Apple ID →
  planner mapping deterministic, which *also* eliminates the duplicate-planner
  race above (no two devices can mint two "Jon"s).
- **Email and name come on file for free** from the Apple ID — *when the
  participant consents* to share them (CloudKit gates this). The unique key is
  always present; the human-readable fields are opt-in.
- `displayName` stays an **editable override** (Apple may say "Jonathan"; the
  travel party calls him "Jon").

This fits ADR-0001 ("iCloud *is* the identity") — no auth, no server, the
account is the key. Blocked on the M5 real-device share-accept flow and on
handling the consent-gated/absent name+email case. A cheap interim stopgap, if
display disambiguation is wanted sooner, is an optional typed `email`/subtitle
on `Planner` — explicitly a placeholder this supersedes.

## Why this is an ADR and not just a bug fix

Both items encode a general law of this architecture: **device-local state is
the only place "who am I" may live, and application-level uniqueness is the
only uniqueness available** — CloudKit removes the database's usual tools
(server-side identity, unique constraints). Every future entity with a
per-planner or logically-unique row (post-visit reviews, trip ranks) inherits
these same two rules.
