# Effort — Ideas quick filters: Food / Stay / Other, and Scheduled / Not scheduled

**Status:** Queued (2026-10-08) · **Summary:** a row of one-tap filter capsules on the Ideas screen,
next to the trip's region capsules: **Food**, **Stay** and **Other** always, and **Scheduled** / **Not
scheduled** while a trip capsule is active. They narrow the list and the map together. No schema
change, nothing synced: the selection is screen state, like the region chips.

Jon asked for it on 2026-10-08, from the iPad Ideas screen during Denmark planning. It sits next to the
ADR-0013 subregion chips and follows their pattern. No ADR: this is a view filter, not a decision.

## Today

- Under the trip capsules (`capsuleBar`), `IdeasScreen` shows `subregionBar`: the active trip's regions
  as toggle chips. It only appears when a trip is active and has two or more regions
  ([IdeasScreen.swift](../../Galavant/Ideas/IdeasScreen.swift)).
- Kind filtering exists, but only in the toolbar **Filter → Kinds** submenu. It's a fine-grained
  multi-select over the 15 `IdeaKind` cases (`IdeasListModel.selectedKinds`, applied in the pure
  `poolFiltered`, [PoolFiltering.swift](../../GalavantLibrary/Sources/GalavantSchema/PoolFiltering.swift)).
- `model.filteredIdeas` feeds the list, the map (`PoolMapView`) and the chat context, so one filter
  narrows all three.

## 1. Kind groups: Food, Stay, Other

Add a pure `IdeaKindGroup` enum (`food`, `stay`, `other`) to `GalavantSchema`, with
`init(kind: IdeaKind?)`:

| Capsule | Kinds | Glyph |
| --- | --- | --- |
| **Food** | `.food`, `.drink` (restaurants, cafés, bars, wineries) | `IdeaKind.food.systemImage` |
| **Stay** | `.stay` | `IdeaKind.stay.systemImage` |
| **Other** | every other kind, **and ideas with no kind** | `mappin.and.ellipse` (the row's no-kind glyph) |

The `.drink`-in-Food call is the architect's. If Jon wants Drink separate, it's one line in the
mapping and one more capsule.

`poolFiltered` takes `kindGroups: Set<IdeaKindGroup> = []`. Empty means no constraint. Otherwise an
idea passes if its group is in the set, so groups combine with **OR**: Food + Stay shows both. It
combines with the existing filters with **AND**, including the menu's fine-grained `kinds`. The menu
keeps its **Kinds** submenu for precise picks; the capsules are the quick path.

## 2. Trip stage: Scheduled, Not scheduled

Shown only while a trip capsule is active. **Scheduled** means the idea is on the itinerary: stage
`.scheduled` (status `.scheduled` with a day, or `.done`), the same derivation as
`IdeasListModel.activeTripStage`. **Not scheduled** means everything else in the lens: considering,
shortlisted and waiting for a day, or not on the trip yet. That's the "what's still open in this
region" view.

The two are **mutually exclusive**. Tapping one turns the other off, and tapping the lit one turns it
off. Neither lit means no constraint. Model it as one optional value, for example
`scheduleFilter: ScheduleFilter?` with `.scheduled` and `.notScheduled`, not two booleans. Switching to
**All** clears it, because it has no meaning without a trip.

Apply it in `filteredIdeas` after `poolFiltered`, as `showMatchesOnly` is. **Derive the stages once per
pass:** build an `[Idea.ID: TripPullStage]` map from `tripIdeas`, then look each idea up in it. Don't
call `activeTripStage(for:)` per idea; it scans `tripIdeas` each time, which makes the filter O(n²).
That's the per-access recompute hazard.

## 3. The row

One horizontally scrolling row under `capsuleBar`:

`[subregion chips…]` · divider · `[Food] [Stay] [Other]` · divider · `[Scheduled] [Not scheduled]`

- The subregion chips keep their current rule (active trip with two or more regions). When they're
  hidden, the row starts with the kind capsules. **The row now always shows**, including under **All**,
  because the kind capsules always apply.
- The trip-stage capsules and their divider show only with an active trip.
- Reuse the subregion chip's look (`.subheadline`, tint fill when on, `.thinMaterial` when off), with
  a leading glyph from the table above. Pull the chip into one small private view that both kinds of
  capsule use, so the styling can't drift.
- The dividers are short vertical `Divider()`s, not text.

**Filter summary and Clear.** `isFiltering`, `filterSummary` (the "Showing N of M · …" line) and
`clearFilters()` include the kind groups and the schedule filter. Kind groups persist across trip
capsule switches, because they're a "what am I looking for" lens. The schedule filter doesn't (see
above). Subregion behavior doesn't change.

## 4. Tidy the tag selection while you're in here (carried from #164's review)

`tag-management` (#164) maps the tag selection through `TagIndex.effectiveSelection` for **filtering**,
but three readers still use the raw `selectedTagIDs`. This effort rewrites the same filter state, so fix
them here:

- `isFiltering` and `filterSummary`. A selected tag that's been deleted in Settings leaves "filtering"
  on, with an empty summary part and a trailing `·`.
- The **Tags** submenu checkmarks in `IdeasFilterMenu`. A selected tag that lost a convergence still
  filters, as its survivor, but nothing shows checked.

Fix: normalize once. When tags change, or in `toggleTag`, set `selectedTagIDs` to
`tagIndex.effectiveSelection(selectedTagIDs)`, so every reader sees survivors only. Alternatively, have
all three readers go through `effectiveSelection`; pick one. Also **build the `TagIndex` once per pass**:
`filteredIdeas` and `sortedTags` currently build one per access, and `filterSummary` builds one inside
its per-tag closure. Hoist it, as `ideaRows` already does, or cache it on the fetched arrays.

**Test (app):** select a tag, delete it, and confirm `isFiltering` is false and the summary has no empty
part. Select a loser id after convergence, and confirm the survivor reads as selected.

## Tests

**Package** (`GalavantSchemaTests`):
1. `IdeaKindGroup(kind:)`: Food covers `.food` and `.drink`, Stay covers `.stay`, Other covers every
   remaining case and `nil`. Iterate `IdeaKind.allCases` so a new case can't fall through silently.
2. `poolFiltered` with `kindGroups`: empty means unchanged; `[.food]`; `[.food, .stay]` is the union;
   `[.other]` includes a no-kind idea; it ANDs with `kinds` and with regions.

**App** (`GalavantTests`, alongside `IdeasListDeleteTests`):
3. With an active trip, `.scheduled` keeps only on-a-day and done ideas, and `.notScheduled` keeps the
   rest of the lens, including ideas not on the trip. Selecting **All** clears the filter.

## Done when

- One PR on branch `effort/idea-quick-filters`. `scripts/check-drift.sh` is green, and headless
  `GalavantTests` pass.
- No schema, migration, sync or contract change.
- The completing PR:
  - adds a DONE-LOG entry;
  - marks this brief Done in `docs/efforts/README.md`;
  - adds to `docs/device-passes.md` under **Verification gates**: *on iPad and iPhone, Ideas → Denmark:
    tap Food, then Food + Stay, then Other; confirm the list and map pins narrow together. Tap
    Scheduled, then Not scheduled. Switch to All and confirm the stage capsules disappear and the kind
    selection stays;*
  - sets `docs/NEXT_UP.md` to exactly this block:

    ```
    # Next Up — Travel profile: Settings entry + ChatGPT briefs + chat

    **Slices:** effort `travel-profile` (one PR, branch `effort/travel-profile`)
    **Briefs:** `docs/efforts/travel-profile-wiring.md`
    **Done when:** per the brief's "Done when"; verification per `docs/verification.md`.
    **Owed:** FIRST WRITE to the synced `travelProfiles` table. Before the TestFlight build: Jon pushes a
    shared profile and a planner overlay from a development build, confirms every field in the
    Development schema, and deploys the schema to Production (`docs/device-passes.md`). The architect
    escalates the PR to Jon before merge.
    **Notes:** No migration and no contract-version bump. The briefs and chat read the profile
    explicitly; no `ModelClient`-boundary injection (ADR-0015 §3 amendment). Start from a fresh `main`.
    ```
