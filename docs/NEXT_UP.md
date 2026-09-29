# Next Up — a daily map on Today (dogfood B2)

**Slices:** effort `today-day-map` (one PR, branch `effort/today-day-map`)
**Briefs:** `docs/efforts/today-day-map.md`; background in ADR-0046 §3–§5 and ADR-0038
**Done when:** per the brief's "Done when", with package and `GalavantTests` coverage; verification per `docs/verification.md`.
**Owed:** Jon's device gates in `docs/device-passes.md` (not executor work).
**Notes:** No schema, sync, or Directions change. Never start the location stream unless already
authorized. Location frames the camera once, on the live day only. Read `planningModel.plan` once;
the card takes plain values. Move `BasePin`; don't copy it. Start from a fresh `main`.
