# Next Up — Don't get killed holding the database lock

**Slices:** effort `launch-lock-suspension`
**Briefs:** [docs/efforts/launch-lock-suspension.md](efforts/launch-lock-suspension.md)
**Done when:** per the brief
**Owed:** see [device-passes.md](device-passes.md)
**Notes:** Continue #197. Its three questions are answered there and in the brief, whose § 2 changed: stop the sync engine before suspending, never the other way round. Read GRDB's `DatabaseSharing` article before writing code. No schema, migration or UI change. `hand-off-purposes`, then `chat-access`, are next in the efforts index.
