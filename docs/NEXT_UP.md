# Next Up — Don't get killed holding the database lock

**Slices:** effort `launch-lock-suspension`
**Briefs:** [docs/efforts/launch-lock-suspension.md](efforts/launch-lock-suspension.md)
**Done when:** per the brief
**Owed:** see [device-passes.md](device-passes.md)
**Notes:** Crash fix from TestFlight 0.2.0 (2), `0xdead10cc` at launch. No schema, migration or sync-contract change. Live shared store only; leave test and restore databases alone.
