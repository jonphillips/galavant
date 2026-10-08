# Effort — Tag management in Settings, duplicate tags converge, tags on Idea rows

**Status:** Done (2026-10-08) · **Summary:** tags get a home in **Settings → Library → Tags**, with
usage counts, rename, delete and "Delete Unused Tags". Tags with the same name converge to one row, the
way ADR-0008 does for other logically unique rows. An Idea row shows its tags. No schema change.

Closes the `open-questions.md` candidates *"Tags aren't visible and can't be managed"* (2026-10-07) and
the tag half of *"Consolidate remaining management UIs into Settings"*. Follows ADR-0008 / effort
`logical-uniqueness-dedup` (lowest-UUID survivor) and the house logical-uniqueness law (jon-platform).

## What's there today, and why Jon sees 24 tags on 0 ideas

- **Storage.** `Tag` (`name`, one FK to `TravelParty`) and `IdeaTag` (one FK to `Idea`, plus a loose
  `tagID`) ([Tag.swift](../../GalavantLibrary/Sources/GalavantSchema/Tag.swift),
  [IdeaTag.swift](../../GalavantLibrary/Sources/GalavantSchema/IdeaTag.swift)).
- **Surfaces.** Tag editing in the Idea form, including the multi-select `TagPickerView`. Tag labels on
  `IdeaDetailView`. A `TagManagerView` with swipe-to-delete and rename, reached only through **Ideas →
  Filter → Tags → Manage Tags…**, and that entry only shows once a tag exists. Jon didn't know it was
  there.
- **The 24 tags.** `DemoFixtures` creates 12 tags and tags demo ideas with them. `--seed-demo` ran on
  two devices during development. `Tag.findOrCreate` dedupes by name only within one device's store, so
  after sync there were two of each tag. Deleting the demo ideas cascaded away their `IdeaTag` rows,
  which left the 2026-10-07 backup with 24 tags and 0 joins.
- **The real gap.** Nothing converges two tags with the same name that were created on different
  devices. Once Wendy tags too, `rainy-day` created on both phones offline gives two tags. Their
  `findOrCreate` picks `.first` from an unordered fetch, so each device can attach a different one. The
  ADR-0008 pass covered `IdeaTag` pairs, not `Tag` names.

## 1. Tag operations move into `GalavantSchema`, with convergence

All tag writes become tested operations in the package. The view models call them and keep no write
logic. Today `IdeasListModel+Taxonomy.swift`'s `deleteTags`/`renameTag` hold that logic, so move it out.

- **Logical key: `(travelPartyID, normalized name)`.** Normalized means trimmed and compared
  case-insensitively, the rule `findOrCreate` already uses. Put it in one helper, which every tag
  operation uses.
- **Survivor: the lowest `id`.** Tags carry no creation date, and the `logical-uniqueness-dedup` brief
  settled on lowest-UUID for exactly that case. Every device picks the same survivor on its own.
  **Don't add a column.**
- **`Tag` has children, so repoint before deleting.** `Tag.convergeDuplicates(in:)` handles each
  duplicate group. Repoint every loser's `IdeaTag.tagID` to the survivor. Then collapse any
  `(ideaID, tagID)` pair that's now duplicated, using the existing `convergingByKey` helper. Then delete
  the losers. It's one write, idempotent, and a no-op when there are no duplicates.
- **Where it runs: the owning writes, as with `TravelParty.ensureDefault`.** That means `findOrCreate`
  (which then returns the survivor, never `.first`), rename, and once when the Settings Tags screen
  appears. That covers rows that arrived by sync. A plain read never writes.
- **Rename onto an existing name merges.** Renaming `michelin` to `Michelin` when `Michelin` exists
  leaves one tag carrying both tags' ideas. The rename UI says so before saving: *"Merges with the
  existing tag “Michelin”."*
- **Other operations.** `Tag.delete(ids:in:)` also deletes the tags' `IdeaTag` rows. That's the current
  hand cleanup, since `tagID` is a loose UUID. `Tag.deleteUnused(in:)` deletes tags with no `IdeaTag`
  and returns the count.

## 2. A pure `TagIndex` read model

Add a value type in `GalavantSchema`, built from `[Tag]` and `[IdeaTag]`. It's the one projection the
screens read:

- tags collapsed by logical key, so nothing shows a name twice even before convergence has run;
- the number of ideas using each tag;
- tag names for each idea, sorted case-insensitively;
- `IdeaTag` rows whose `tagID` matches no tag are ignored. That happens when one device deletes a tag
  while the other tags an idea with it.

**Build it once per change, not per row** (house memory: per-access recompute hazard). `IdeasListModel`
already exposes `headerThumbnailByIdea` and others as computed properties read once per row. Don't add
another of those. Build the index once per body pass, or cache it when the fetched arrays change. Either
works if the row loop does dictionary lookups only.

## 3. Settings → Library → Tags

A new **Tags** row in `SettingsScreen`'s **Library** section, between Regions and Planners. It pushes a
`TagManagementSettingsView` with its own `TagManagementSettingsModel`, following the
`RegionManagementSettingsView`/`Model` pattern. It doesn't take `IdeasListModel`.

- Each row shows the name and its use: *"3 ideas"*, *"1 idea"* or *"Unused"*. Sort by name.
- Tap a row to rename it. Swipe to delete. Deleting a tag that's in use asks first: *"Remove “Michelin”
  from 3 ideas?"*. An unused tag deletes without asking.
- When any tag is unused, a section at the top offers **Delete Unused Tags (N)** with one
  confirmation. That's how Jon clears the 24.
- Empty state: *"No tags yet. Add tags to an idea from its editor."*
- On appear, run `Tag.convergeDuplicates`.

**Retire the filter-menu manager.** Remove **Manage Tags…** from `IdeasFilterMenu`, the `managingTags`
binding, the sheet in `IdeasScreen`, and `TagManagerView`. Leave **Manage Regions…** alone; it isn't in
scope. The filter's **Tags** submenu stays.

**The tag filter must survive a deletion.** `IdeasListModel.selectedTagIDs` filters on *all* selected
tags. If a selected tag is deleted in Settings, or loses a convergence, a stale id would filter the pool
to nothing. Intersect the selection with the live tag ids (from the index) when filtering, or prune it
when tags change. Map a converged loser's id to its survivor if that's cheap; otherwise dropping it is
fine.

## 4. Tags on Idea rows

`IdeaRow` ([IdeaRow.swift](../../Galavant/Ideas/IdeaRow.swift)) takes `tagNames: [String] = []`. When the
list isn't empty, show one more line in the text stack, after the region and notes lines: a small tag
glyph (`Icon.tag`), then the names joined by `" · "`, in `.caption` and `.secondary`, `lineLimit(1)`
with tail truncation. No chips; the row is already busy. The same line shows in both accessory modes
(eternal pool and active trip). `IdeasScreen` passes the names from the `TagIndex`.

## Tests (package, `GalavantSchemaTests`)

1. **Convergence.** Seed `Michelin` (higher id) and `michelin` (lower id), with ideas A and B on the
   first tag and B and C on the second. After convergence there's one tag (the lower id) on A, B and C.
   B has exactly one `IdeaTag`. Running it again changes nothing.
2. **`findOrCreate` returns the survivor** when duplicates exist, and creates nothing.
3. **Rename collision merges** into one tag, with the new name and every idea from both. Run it both
   ways: once with the renamed tag holding the lower id, once with the existing tag holding it. The
   lower id survives each time.
4. **`deleteUnused`** deletes only zero-use tags and returns the count. **`delete(ids:)`** also removes
   the joins.
5. **`TagIndex`:** counts, sorted names per idea, the duplicate-name collapse, and an `IdeaTag` whose
   tag is missing.
6. **Filter selection.** A selected id that's gone from the index doesn't empty the pool (wherever the
   pure filter lives; `PoolFiltering` takes `tagIDs`).

## Done when

- One PR on branch `effort/tag-management`.
- `scripts/check-drift.sh` is green. Headless `GalavantTests` pass. Run `xcodegen generate` for the added and
  removed app files, and commit the regenerated project.
- No schema, migration or contract change.
- The completing PR:
  - adds a DONE-LOG entry;
  - marks this brief Done in `docs/efforts/README.md`;
  - adds to `docs/device-passes.md`: *Settings → Library → Tags: delete the unused demo tags; tag an
    idea and confirm the tag shows on its row; create the same tag name on iPhone and iPad (one offline)
    and confirm one tag remains after sync and opening Settings → Tags;*
  - sets `docs/NEXT_UP.md` to exactly this block:

    ```
    # Next Up — Ideas quick filters (Food / Stay / Other, Scheduled / Not scheduled)

    **Slices:** effort `idea-quick-filters` (one PR, branch `effort/idea-quick-filters`)
    **Briefs:** `docs/efforts/idea-quick-filters.md`
    **Done when:** per the brief's "Done when"; verification per `docs/verification.md`.
    **Owed:** Jon's device gates in `docs/device-passes.md` (not executor work).
    **Notes:** View filters only: no schema, sync, or persistence. Builds on the tag effort's
    `IdeasListModel` / `poolFiltered` changes, so start from a fresh `main` after it merges.
    ```
