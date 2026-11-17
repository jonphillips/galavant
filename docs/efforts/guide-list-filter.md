# Effort — Show one of Chat's named lists in the guide, in rank order

**Status:** Dispatched · **Summary:** [ADR-0055](../decisions/0055-trip-rationale-fields.md) D12. When the region guide has a
trip lens, a list picker on the cards' header offers each named ranked list ("Dim Sum", "Soho Indian") that the trip's
stops carry here. Picking one narrows the cards and the map to that list's places, as one section in Chat's order. Ranks
4 and below show a plain number. **No schema change, so no CloudKit deploy.**

**Read first:** ADR-0055 D9–D12; the archived [`guide-deliberation`](archive/guide-deliberation.md) and
[`rank-list-label`](archive/rank-list-label.md) briefs, which built the medals and names this filters by.

## Today

- `TripIdea.rationalePriority` / `rationalePriorityOutOf` / `rationalePriorityList` hold a stop's rank, the size of its
  list, and the list's name. The three are written and cleared together (D10).
- `TripIdea.openChoiceRanks(entries:)` (`TripIdea.swift:345`) gives the guide each idea's best medal-eligible rank among
  open choices (Considering, or in an alternatives ring). `RegionGuideScreen` passes it to `RegionGuideCardRow`, which
  draws `RankMedal` and the list name on the badge line after "On trip".
- `RegionGuideModel.visibleGuide` / `mapGuide` already narrow the guide to a set of idea IDs for a focused slot, through
  the private `RegionGuide.filtered(to:)`. Sections are grouped by accolade ("Michelin · 1 Star"), then "Other places".
- The shelf chips (All / Want to Go / Noted / Not for Me) filter by interest and show counts.

## Part 1. Pure core (GalavantSchema)

- Add `TripIdea.rankedLists(entries:) -> [RankedList]` beside `openChoiceRanks`. `RankedList` holds `name: String` and
  `members: [Member]`, where a member is `ideaID`, `priority` and `isOpenChoice`.
- Take every stop with an `ideaID`, a non-nil `rationalePriority` and a non-nil `rationalePriorityList`, whatever its
  status. Group by the list name, compared exactly as stored (import already trims it). If one idea appears more than once
  in a list, keep its best (lowest) rank, and it counts as an open choice if any of those stops is open, by the same test
  `openChoiceRanks` uses.
- Order members by priority, breaking ties on `ideaID.uuidString` so the order is stable. Order lists by name,
  case-insensitive.
- Stops with a rank but no name are left out. A list's name never appears without a rank (D10 guarantees it).

## Part 2. Model (RegionGuideModel)

- Add `var selectedListName: String?`. Clear it in `selectRegion`, `tripSelected`, and when `category` changes, the same
  places `focusedSlotKey` is cleared.
- `func availableLists(for lens: GuideTripLens, guide: RegionGuide?) -> [TripIdea.RankedList]`: `rankedLists` for the lens
  trip's entries, each list's members narrowed to ideas in the guide built for the **All** shelf for this region and
  category. Drop lists left empty. This keeps "Manchester hotels" out of the London dining guide, and keeps a list in the
  menu while the shelf hides some of its places.
- `selectedList`: the available list whose name equals `selectedListName`. If none matches (the list was renamed by a
  re-rank, or emptied), treat it as no selection and show the whole guide. Don't write the property back from a getter.
- Filtering: when a list is selected, `visibleGuide` and `mapGuide` narrow to the list's ideas **and** whatever they
  already narrow to (the shelf, and a focused slot's IDs). The result is one section, titled with the list's name, id
  `"list"`, with cards in the list's order. Add a `RegionGuide.ordered(as ideaIDs: [Idea.ID], title:)` next to
  `filtered(to:)` rather than a second filtering path in the view.
- The shelf chip counts stay as they are, counting the region and category without the list. Don't recount.
- The model exposes a per-idea rank for the selected list (`[Idea.ID: TripIdea.RankedList.Member]`) for the card row.

## Part 3. View

- **Picker.** In `guideList`, when the lens exists and `availableLists` isn't empty, put a `Menu` at the top of the first
  card section's header (where "Other places" sits in Jon's screenshot, on its trailing side). Its label is
  "All places" with `chevron.up.chevron.down` when nothing is picked, and the list's name when one is. Items: "All places"
  then a divider, then each list's name with its member count ("Dim Sum · 7"), checkmarked when selected. With a list
  picked, the section header is the list's name, and the menu stays on it so Jon can switch or go back to All.
  Hide the picker entirely with no lens or no named lists.
- **Card rank.** With a list picked, the card's badge line shows that list's rank, not `openChoiceRanks`. An open choice
  ranked 1–3 wears its `RankMedal` as today (D9/D11 eligibility: `ChatRankMedal.tier` with that member's priority and the
  stop's `priorityOutOf`). Every other member shows its rank as a plain numeral in the same 18 pt circle, outlined in
  `.secondary`, no fill. Drop the list-name text after it, since the header already says it. VoiceOver: "Chat's 4th
  choice" for a plain numeral; keep `RankMedal`'s existing label for medals.
- With nothing picked, the cards look exactly as today.
- **Map.** `poolMap` already takes `mapGuide`, so it follows the filter. No medals or numbers on pins (D9).
- **Slot focus.** A focused open slot and a picked list combine: the cards are the list's places that fit the slot, in
  rank order. A filled slot still hides the cards, as today.
- iPhone: the picker lives in the same section header in list mode. In map mode the filter still applies; no extra
  control is needed there.

## Tests

- `rankedLists`: groups by name; leaves out unnamed ranks; includes placed (scheduled) stops with `isOpenChoice == false`;
  an idea in one list twice keeps its best rank; members order by priority; lists order by name.
- Model (headless app target, `RegionGuideModel` with seeded data): two named lists on one trip, one with a place outside
  the region. The London dining guide offers only the in-region list. Picking it gives one section, titled with its name,
  in rank order, and the map guide has the same ideas. A shelf that hides two members narrows further while the list stays
  offered. Changing region, trip or category clears the pick. A re-rank that renames the list makes the pick fall back to
  the whole guide.

## Done when

- `scripts/check-drift.sh` is green, plus the headless app-target run, with its "Test run with N tests" line in the PR.
- No migration and no `cloudkit-expected-fields.txt` change.
- Device gate (iPad, TestFlight build), in `device-passes.md`: on the Sam Fender UK trip, with a ranked Dim Sum list and a
  second named list staged from a new Chat conversation (after re-pasting the project instructions), open the London guide.
  The picker offers both lists only where their places are in London. Pick Dim Sum: the cards are those places, 1 to N,
  with medals on the open top three and plain numbers after; the map shows only them. Tap a Lunch · Open slot: the list
  narrows to places that fit it. Pick All places: the guide is as before. Judge: does picking a list make the comparison
  easier, and does the header placement feel findable?
