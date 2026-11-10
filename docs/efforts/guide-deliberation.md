# Effort — Deliberate in the Guide: medals in the trip lens, a Guide button on each day, Michelin's full ladder

**Status:** Ready · **Summary:** [ADR-0055](../decisions/0055-trip-rationale-fields.md) D11 and the 2026-11-10
amendment to [ADR-0053](../decisions/0053-taste-record-and-region-guide.md) D8. With a trip lens on, guide cards wear
Chat's gold, silver and bronze. Each itinerary day header with a region gets a small Guide button that opens the guide on
that region with the lens on that trip. The hand-set Michelin rating gains Guide and Bib Gourmand, and is saved under the
same source name as a captured one. **No schema change.**

**Read first:** ADR-0055 D9 and D11; ADR-0053 D8; the archived
[`chat-reevaluation`](archive/chat-reevaluation.md) brief, which added `RankMedal` and `ChatRankMedal`;
[ADR-0013](../decisions/0013-ideas-screen-trip-shopping-surface.md) for the itinerary → Ideas hand-off this extends.

## Today

- `ChatRankMedal.tier(priority:priorityOutOf:)` (`TripIdea.swift`) and `RankMedal` (`Galavant/Design/RankMedal.swift`)
  draw the medals. `TripIdeasView` passes `rationalePriority` / `rationalePriorityOutOf` into `PlanningRow` for
  Considering rows and alternatives options. The guide doesn't show them.
- `RegionGuideScreen` builds each `RegionGuideCardRow` with `badge: tripLens?.badgeLabel(for:)`, the "On trip" / "Tue
  dinner" capsule. `RegionGuideModel` already fetches `TripIdea.all` and filters it by `lens.trip.id`.
- `SectionHeader` (`TripItineraryDayHeader.swift`) is one `Button` (it opens Shape Trip on that day) and shows
  `model.dayRegion(forDay:)`'s name.
- `AppRouter.browseIdeas(forTrip:regionID:)` sets `ideasScope` and flips to `.ideas`. `IdeasScreen.applyIdeasScope()`
  consumes it and clears it. `AppRouter.openTrip` survives the flip, so the Trips section reopens the trip.
  `IdeasListModel.destination = .guide(RegionGuideScope)` is how the Ideas toolbar opens the guide.
- `IdeaFormModel.manualRating: Int` (0 = none, 1–3) and `IdeaFormView.ratingSection` offer None and ★–★★★, or 🗝–🗝🗝🗝
  for a stay. `applyManualRating` writes a `.manual` `.stars` `IdeaEvaluation` with `sourceName: "Michelin"`.
- `EvaluationRecognizers` writes captured Michelin judgments under `GuideHosts.michelin.name`, which is
  `"Michelin Guide"`: stars as `.stars` ("★★"), Bib Gourmand as `.badge` ("Bib Gourmand"), and Plate / Recommended as
  `.recommendation` ("Recommended"). `RegionGuide` groups cards by `(sourceName, nativeDisplay)`, so a hand-set "Michelin
  · ★★" and a captured "Michelin Guide · ★★" land in two different sections. `IdeaEvaluation.headlineRank` already orders
  stars, then badge, then recommendation.

## Part 1. Medals in the guide's trip lens (ADR-0055 D11)

- Pure, in GalavantSchema next to `ChatRankMedal`: a small `ChatRank` value (`priority`, `priorityOutOf`), and
  `ChatRankMedal.openChoiceRanks(entries: [TripIdea]) -> [Idea.ID: ChatRank]`. Do it in **one pass** over the trip's
  entries. Keep an entry only if it has an `ideaID`, it is an open choice (`status == .considering`, or
  `alternativeGroupID != nil`), and `tier(...)` is non-nil. When an idea has more than one, keep the lowest priority.
  "Considering" means what `TripPlan.considering` means: reuse its predicate, and don't write a second one. If it can't
  be called on raw entries, lift it so both use one function.
- `RegionGuideModel` computes the map once per lens, from the entries it already filters, not once per card.
- `RegionGuideCardRow` takes an optional `ChatRank`. Draw `RankMedal` on the bottom line, after the badge capsule, in
  one `HStack`. If there's a medal but no badge, the medal stands alone on that line.
- No medals on the guide map, on the lens's slot cells, or without a lens. Nothing sorts by rank.

## Part 2. A Guide button on each itinerary day header (ADR-0053 D8, amended)

- Router: replace `IdeasScopeRequest`'s implicit "browse" with an enum, so a request can't be both or neither:
  `enum IdeasHandoff { case browse(tripID: Trip.ID, regionID: MapRegion.ID?); case guide(tripID: Trip.ID, regionID: MapRegion.ID) }`,
  carried by the request with its fresh `id`. Keep `browseIdeas(forTrip:regionID:)` and add
  `openGuide(forTrip:regionID:)`. `PlaceIdeaSheet` keeps calling `browseIdeas`.
- `IdeasScreen.applyIdeasScope()`: for `.guide`, look the region up in the model's regions and set
  `model.destination = .guide(RegionGuideScope(region:category: .dining, preferredTripID: tripID))`. This replaces any
  guide or dossier that was open. If the region is gone, fall back to `.browse`'s behavior. Clear the request either
  way.
- `SectionHeader`: when the day has a region, put a small borderless button at the trailing edge of the header, in an
  `HStack` beside the existing button. It's a sibling, never nested inside it. Use the same symbol as the Ideas toolbar's
  Guide button (`book.and.wrench`). If you add it to `Icon`, point the toolbar at it too. Accessibility label:
  "Open the Guide for <region>". Tapping it calls `router.openGuide(forTrip:regionID:)`. The header's own tap still opens
  Shape Trip. A day with no region gets no button.
- Check every place `SectionHeader` renders, on iPad and iPhone, and run the jon-platform § Controls check: one symbol,
  the same meaning everywhere.

## Part 3. Michelin's full ladder

- Pure, in GalavantSchema: `enum MichelinDistinction: Hashable { case none, guide, bibGourmand, stars(Int), keys(Int) }`.
  Shape it however suits the picker, but these things are fixed:
  - Restaurants and every other non-stay kind are offered None, Guide, Bib Gourmand, ★, ★★, ★★★. A stay is offered None,
    Guide, 🗝, 🗝🗝, 🗝🗝🗝. There is no Bib for a stay.
  - Storage, so a hand-set judgment reads exactly like a captured one: `sourceName` is `"Michelin Guide"` (pin it equal
    to `GuideHosts.michelin.name` in a test). Guide is kind `.recommendation` with text and display `"Recommended"`. Bib
    is `.badge` with `"Bib Gourmand"`. Stars and keys stay as today's `.stars`, with `nativeValueMax: 3`.
  - A round trip: `init(evaluation:)` reads back a manual Michelin evaluation of any of those three kinds. It accepts
    the old `"Michelin"` source name too.
- `IdeaFormModel`: `manualRating: Int` becomes `MichelinDistinction`. Loading finds the manual Michelin evaluation of any
  of the three kinds. Saving removes every prior manual Michelin evaluation of those kinds (under either source name),
  then writes the new one. None writes nothing. The picker and its header say "Michelin". The footer stays as it is.
- Existing rows: there's no data migration. Hand-set rows already saved under `"Michelin"` are rewritten the next time
  their idea is saved. Until then, `RegionGuide`'s accolade grouping treats `"Michelin"` and `"Michelin Guide"` as one
  source, through one tested helper (`IdeaEvaluation.canonicalSourceName`), so the guide doesn't split a section in two.
- The guide's sections then fall out by themselves: ★★★, ★★, ★, Bib Gourmand, Recommended, in `headlineRank` order. Check
  the order once, in a `RegionGuide` test.

## Tests

- `openChoiceRanks`: a Considering stop and a ring option count; a shortlisted or scheduled non-ring stop doesn't; a
  one-place return (`outOf == 1`) and rank 4 don't; two open stops for one idea keep the lower priority; freeform stops
  are ignored.
- `MichelinDistinction`: every case round-trips through its evaluation fields. A stay never offers Bib. The old
  `"Michelin"` source reads back. Guide and Bib are stored exactly as the recognizers store them.
- `RegionGuide`: a hand-set `"Michelin"` ★★ and a captured `"Michelin Guide"` ★★ share one section. The section order
  is stars (most first), Bib Gourmand, then Recommended.
- Router / scope (if the model is testable without the view): `.guide` sets the guide destination with the trip as
  preferred; a missing region falls back to browse.

## Done when

- `scripts/check-drift.sh` is green, plus the headless app-target run, with its "Test run with N tests" line in the PR.
- No CloudKit schema change: `cloudkit-expected-fields.txt` is untouched.
- Device gate (iPad, TestFlight build): open Sam Fender UK and tap the new Guide button on a London day. The guide opens
  on London, Dining, with the lens on the trip. The cards for Chat's ranked Considering places wear their medals beside
  "On trip". Tap Trips, and the trip is where you left it. On a place's form, set Michelin to Bib Gourmand, then to Guide.
  The row and the guide's sections show each one. A place hand-set to ★ earlier sits in the same guide section as a
  captured ★. On iPhone, the day header button opens the same guide. Then judge: Is the button findable without
  crowding the header? Do the medals help in the guide, or add noise?
