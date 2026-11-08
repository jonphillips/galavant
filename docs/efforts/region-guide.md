# Effort — Region guide: see what we know about a place's restaurants and hotels

**Status:** Ready · **Summary:** Slice 3 of [ADR-0053](../decisions/0053-taste-record-and-region-guide.md). A guide screen
reached from Ideas, scoped to one saved region and one category, Dining or Hotels. It shows kept Ideas as cards, grouped by
their headline accolade, with shelves for Want to Go, Noted, and Not for Me. Do Not Do places are hidden by default. It's
built to be judged on a device, and that review decides what comes next. No schema, migration, sync, or hand-off change.

**Read first:** ADR-0053 D1 and D6; the [idea-dossier](idea-dossier.md) brief, since this screen opens that dossier; ADR-0015
(accolades as the source wrote them); and `PRODUCT.md` § The other loop and § Scoping the pool.

**Depends on `idea-dossier`.** Start from a `main` that has it.

## Today

- `poolFiltered(_:regions:kinds:kindGroups:…)` (`GalavantSchema/PoolFiltering.swift`) already scopes to regions and
  `IdeaKindGroup`. An unlocated idea never matches a region.
- `IdeaEvaluation.headline(forIdea:from:knownIdeaIDs:)` picks a row's accolade: current before stale, then by kind (stars,
  score, rank, badge, …), then by recency. `headlineRank` is private.
- `Interest.standing(_:)` gives `.match`, `.neutral`, or `.passed`. `.passed` needs two Do Not Do ratings, so one person's
  Do Not Do stays `.neutral`.
- `IdeasScreen` lays out list and `PoolMapView` side by side on regular width, with a toggle on compact. A map POI tap opens
  the capture form (`mapPlaceTapped`).
- After `idea-dossier`, a card tap can open `IdeaDetailView(ideaID:…)` with the same presentation Ideas uses.

## Part 1. The read-model (`GalavantSchema`)

```swift
public enum GuideCategory: String, CaseIterable, Sendable { case dining, hotels }  // .food and .stay kind groups
public enum GuideShelf: String, CaseIterable, Sendable { case all, wantToGo, noted, notForMe }

public struct RegionGuide: Equatable, Sendable {
  public struct Card: Identifiable, Equatable, Sendable {
    public var idea: Idea
    public var accolade: IdeaEvaluation?          // the headline, current only
    public var interests: [PlannerInterest]       // as IdeaDossier lists them
    public var standing: MatchStanding
    public var latestNote: TasteNote?
    public var noteCount: Int
    public var id: Idea.ID { idea.id }
  }
  public struct Section: Identifiable, Equatable, Sendable {
    public var title: String                      // "Michelin · ★★", or "Other places"
    public var cards: [Card]
    public var id: String { title }
  }
  public var sections: [Section]
  public var counts: [GuideShelf: Int]            // for the shelf chips, computed in the same pass

  public init(
    region: MapRegion, category: GuideCategory, shelf: GuideShelf,
    ideas: [Idea], evaluations: [IdeaEvaluation], interests: [IdeaInterest],
    planners: [Planner], notes: [TasteNote])
}
```

Pinned:

- **Membership is `poolFiltered`,** with that one region and the category's kind group. No second region rule.
- **Shelves are derived from interest and notes.** No list entity, flag, or column (ADR-0053 D6):

  | Shelf | An idea is on it when |
  | --- | --- |
  | **Not for Me** | at least one planner says Do Not Do, and nobody says Want to Do or Must Do |
  | **All** (the default) | it isn't Not for Me |
  | **Want to Go** | at least one planner says Want to Do or Must Do |
  | **Noted** | it has at least one taste note, and it isn't Not for Me |

  Not for Me is deliberately wider than `.passed`, because one person's Do Not Do is enough to hide a place by default. It's
  one tap away, and its chip shows a count so nothing disappears silently.
- **Grouping is by headline accolade, as the source wrote it.** A section is a distinct current headline's `sourceName` and
  `nativeDisplay`. Sections order by the headline kind rank (make `headlineRank` `package`, and don't copy it), then
  `nativeValueNumber` descending, then title. A card with no current accolade goes into **Other places**, last. Within a
  section, matches come first, then name, case-insensitive. Never merge two sources' scales (ADR-0015).
- **One pass.** The init resolves interests, headlines, and notes once into dictionaries, then walks the ideas. The view
  builds the guide **once per body, ahead of the `List`**, and cards take values. Nothing in a card reads the model. That's
  the plan-snapshot lesson: a per-row derivation is what froze the itinerary.
- **Hotel cards lead with the note.** The card reads `IdeaDossier`'s emphasis rule, so it doesn't restate it.

**The ADR's "Favorites" shelf is "Noted" here, on purpose.** Notes carry no sentiment, and Galavant doesn't interpret them
(ADR-0053 D3). A note about the hotel we hated would put it on a shelf called Favorites. "Noted" says what's true: we've
written about it. If the device review wants a real Favorites, that's a decision, maybe an interest level, maybe nothing, and
not this slice's.

## Part 2. The screen (app target)

`RegionGuideModel` (`@Observable`) and `RegionGuideScreen`.

- **Entry:** a **Guide** toolbar button on `IdeasScreen` pushes the screen onto the existing stack. It opens on:
  - region: the Ideas region filter if one is set; else the active trip's single subregion when exactly one is on; else the
    last guide region (device-local `@Shared(.appStorage)`); else none, and the region prompt shows.
  - category: Hotels when the Ideas kind-group filter is exactly Stay; else Dining.

  Put that choice in a pure function in `GalavantSchema` and test it.
- **Header:** a region menu (saved `MapRegion`s, name-ordered), Dining and Hotels segments, and shelf chips with counts.
- **Body:** the cards list, with `PoolMapView` showing just the visible cards and framed to the region. Use the Ideas layout:
  side by side on regular width, a toggle on compact.
  - A card tap opens the dossier with S2's presentation: a push on compact, a column swap on regular. If S2 built the swap
    inline in `IdeasScreen`, lift it into one shared container now rather than copying it.
  - A pin tap opens the same dossier.
  - A map POI tap opens the capture form through the same path as `IdeasListModel.mapPlaceTapped`. Keeping a place is one
    deliberate tap (ADR-0053 D6).
- **Card:** the header thumbnail, name, locality (`address`, else `regionName`), the accolade as written, both planners'
  levels, a visited check, and the latest note's first line with who wrote it. A hotel card shows two lines of the note above
  the accolade.
- **Fetches:** ideas, planners, interests, and evaluations whole, as Ideas does. Taste notes only where `ideaID` is not nil.
  Header thumbnails only, as `IdeasListModel.headerThumbs` selects them.
- **Empty states:**
  - With no saved regions: "Save a region from the Ideas map to see its guide."
  - With an empty shelf, say which shelf is empty and how many places Not for Me holds.

## Tests

**Package:**

- Shelves, as a table: two planners, each nil, Do Not Do, Could Do, or Want to Do. Each combination lands on the right
  shelves, and the counts match.
- Membership: an unlocated idea and an idea outside the region are absent, and a hotel is absent from Dining.
- Grouping: Michelin ★★★, ★★, and ★, a score source, and a stale ★ (which goes to Other places). The section order and
  titles match the pin, and two sources with the same display stay separate.
- Within a section, a match sorts first.
- `latestNote` is the newest of three, and `noteCount` is 3.
- The initial scope function covers every branch of the entry rule.

**App target:** `RegionGuideModel` over the in-memory database equals `RegionGuide` built from the same rows. Writing a Do
Not Do for the current planner moves the idea to Not for Me after a load.

## Out of scope

- The universe: an external list, anything device-local beside Ideas, or "Add all" (S5, after its gate).
- Recommendation records (S4), and any Favorites flag or new interest level.
- Changing the Ideas list's own filtering. Do Not Do stays visible there. The device review decides whether Ideas follows.
- An Other category, a multi-region guide, and sorting controls.
- The in-app browser with field capture. Raise it on the PR if the dossier link feels like the gap.

## Done when

- The Guide button opens the screen with the scope rule above, and region, category, and shelf all change it in place.
- Cards, sections, and counts come from one `RegionGuide` per body.
- Every test above is green, and the dossier, Ideas, and evaluation tests pass unchanged.
- `scripts/check-drift.sh` passes, and the app-target tests ran headless and passed (`verification.md`). Compile only, with
  no simulator walkthrough.
- The closeout carries this gate, word for word, with `--gate`:

  > **Region guide (`region-guide`).** On the iPad, TestFlight build. In Ideas, pick a region you've collected restaurants in
  > and tap Guide: it opens on Dining for that region. Sections follow the accolades as the guides wrote them, and unrated
  > places sit last. Mark one Do Not Do from its dossier: it leaves All, and the Not for Me count goes up. Switch to Hotels: the
  > cards lead with your notes. Try Want to Go and Noted. Tap a pin, then a card: the same dossier, with the map still beside
  > it. Tap a restaurant on the map you haven't saved: the capture form opens. Then on the iPhone, open the guide and flip to the
  > map. **Then judge it, and write the answers in the PR or to the architect:** Did you browse past what you came for? Are
  > the sections the right cut, or would you rather group by area or by interest? Is Noted useful, or do you want a real
  > Favorites? Should the Ideas list hide Do Not Do too? What did you reach for that isn't there?
