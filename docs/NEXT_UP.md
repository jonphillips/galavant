# Next Up — booking Scope 4: handoff "book ahead" hint + Today warning

**Slices:** effort `booking-scope-4-hint-and-today`, Parts A + B (one PR, branch `effort/booking-scope-4-hint-and-today`)
**Briefs:** `docs/efforts/booking-scope-4-hint-and-today.md`; background in ADR-0047 §2–§4
**Done when:** per the brief's "Done when", with package tests; verification per `docs/verification.md`.
**Owed:** Jon's device gates in `docs/device-passes.md` (not executor work).
**Notes:** No schema or sync change. Keep the contract marker at v1. The advisory `book_ahead` field
must never fail a paste. Seed `.toBook` only where nothing is stored. Start from a fresh `main`.
