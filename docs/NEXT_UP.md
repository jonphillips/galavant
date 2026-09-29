# Next Up — Evaluate: stop duplicating candidate sets on re-paste

**Slices:** effort `evaluate-duplicate-candidate-sets` (one PR, branch `effort/evaluate-duplicate-candidate-sets`)
**Briefs:** `docs/efforts/evaluate-duplicate-candidate-sets.md`
**Done when:** per the brief's (a)–(c), with package tests; verification per `docs/verification.md`.
**Owed:** Jon's standing device gates — `docs/device-passes.md` (not executor work).
**Notes:** This changes how committed rows are identified (links to an existing row instead of
inserting), so the architect should expect to escalate to Jon per ADR-0005 D9. Next candidate after
this: booking-status Scope 4 (ADR-0047), in `docs/open-questions.md`.
