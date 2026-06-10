# ADR-0003: One fully-shared household library

*Status: accepted — 2026-06-10*

## Decision

Everything — the idea pool, trips, tags, regions — is shared by default
between the two household members. Both read/write everything. There is no private
library and no per-record sharing UI.

## Why

For exactly two people planning travel together, "is this synced to her yet?" should
never be a question. One library is the simplest mental model and the simplest
CloudKit design. Per-trip CKShare granularity was considered and rejected as
complexity with no household benefit.

## Likely shape (validate at the sync milestone)

One iCloud account owns the data; the spouse accepts a single share that covers the
whole record graph (e.g. a root "Household" record everything descends from, or
SQLiteData's record-sharing mechanism applied at the top). **This is the #1 technical
risk in the project** — SQLiteData's CloudKit sharing must support the
everything-shared-with-one-person pattern with acceptable ergonomics. Prove it with a
toy entity on two real devices before building features on top (Roadmap M1).

## Consequences

- No per-item ownership/privacy semantics anywhere in the schema (no `mine` flags —
  V1/V2's `mine` column dies here). An optional `addedBy` attribution column is fine.
- Conflict story can be simple last-writer-wins; two users in one household rarely
  edit the same field simultaneously.
