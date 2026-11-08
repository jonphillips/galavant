# Effort — Idea dossier: tapping a place reads it before it edits

**Status:** Done · **Summary:** Slice 2 of [ADR-0053](../../decisions/0053-taste-record-and-region-guide.md). Tapping an idea in
Ideas, or its pin, opens a read-first dossier instead of the editor. The dossier leads with what we already know: accolades,
photos, both planners' interest, and our taste notes. Edit is one tap away. One dossier view and model serve Ideas, Trip, and
Today. No schema, migration, sync, or hand-off change.

**Read first:** ADR-0053 D1, D2, and D6 ("the dossier is primary"); ADR-0015 (evaluations are shown as the source wrote them,
never normalized); and jon-platform `docs/ios/ui-and-platforms.md`.

## Today

- `IdeasListModel.ideaTapped(_:)` sets `destination = .form(...)`, so a row tap and a pin tap (`IdeasScreen.pinTapped`) both
  open `IdeaFormView`. The pool has no reading surface.
- `IdeaDetailView` is the reading surface, reached only from `TripDetailContent` (a popover on iPad, a sheet on iPhone) and
  `TodayView`. It's pure presentation: each host resolves `tagNames`, `interests`, `evaluations`, and `headerImage` itself,
  through `TripPlanningModel+IdeaDetails.swift` and `tagNames(for:)`.
- Trip passes `headerThumbnailByIdea[idea.id]`, the **thumbnail** bytes, as the header image. Today passes display bytes
  when it has them.
- Accolades sit below the link and the interest rows. Taste notes come from `TasteNoteReadOnlySection`, which fetches every
  note in the database and filters in the view.
- Photos aren't shown at all. Only `IdeaFormView` shows the gallery.
- `IdeasScreen` sits in one `NavigationStack` on both platforms (`AppContainer`). On regular width it's the list (max 420
  pt) beside the pool map.

## Part 1. The read-model (`GalavantSchema`)

The pure value that owns every decision the view would otherwise make. Keep it out of the app model (watch for fat models:
`IdeasListModel` is already 593 lines).

```swift
public struct IdeaDossier: Equatable, Sendable {
  public var idea: Idea
  public var accolades: Accolades             // current, then historical, via IdeaEvaluation.currentAndHistorical
  public var interests: [PlannerInterest]     // every party planner, name-ordered; level nil = not rated
  public var standing: MatchStanding          // Interest.standing over those levels
  public var notes: [TasteNote]               // this idea's notes, newest first
  public var tagNames: [String]               // canonical names after tag convergence (ADR-0008)
  public var photos: [DossierPhoto]           // non-header images in sortRank order: id + thumbnail only
  public var emphasis: Emphasis               // .notesFirst for IdeaKindGroup.stay, else .accoladesFirst

  public init(idea:evaluations:interests:planners:notes:tags:ideaTags:photos:knownIdeaIDs:)
}

public struct PlannerInterest: Equatable, Sendable { public var planner: Planner; public var level: Interest? }
public struct Accolades: Equatable, Sendable { public var current: [IdeaEvaluation]; public var historical: [IdeaEvaluation] }
public struct DossierPhoto: Identifiable, Equatable, Sendable { public var id: ImageAsset.ID; public var thumbnail: Data }
public enum Emphasis: Sendable { case accoladesFirst, notesFirst }
```

Pinned:

- **One builder, three hosts.** Ideas, Trip, and Today all get their dossier from this init. Delete
  `TripPlanningModel+IdeaDetails.swift`'s `interests(for:)` and `evaluations(for:)` once nothing calls them, and drop
  `tagNames(for:)` if its only caller was the detail.
- **Interest shows every planner,** pending ones included, so a dossier says "Wendy hasn't rated this" instead of hiding
  her. That's different from `IdeasListModel.ratingRow(for:)`, which goes quiet when nobody has rated. Converge duplicate
  interest rows the way `convergedInterests` does (ADR-0008).
- **Emphasis is the only kind-specific rule.** A stay leads with what happened (notes), and everything else leads with what
  others think (accolades). S3's hotel card reads the same value.
- **Accolades render as the source wrote them.** `nativeDisplay`, source name, year, confidence, and staleness, exactly as
  `EvaluationRow` does today. Historical ones sit under a disclosure.

## Part 2. One model per open dossier (app target)

`IdeaDossierModel`, `@Observable`, created with an `Idea.ID` by whichever view presents the dossier.

- **Every fetch is scoped to the one idea**: the `Idea` row, its evaluations, interests, notes, `IdeaTag` joins, and
  `ImageAsset` rows selected as `id`, `thumbnail`, `sortRank`, and `isHeader`. Tags and planners are small and stay whole.
  Never fetch the whole `TasteNote` or `ImageAsset` table. Display bytes load only for the header, plus one photo when it's
  opened full screen.
- **The header uses display bytes, never the thumbnail.** That fixes Trip's soft header for free. If there's no header row,
  there's no header image: don't promote a gallery photo.
- `setMyInterest(_:)` writes through `IdeaInterest.set`, using the current planner the way `IdeasListModel` resolves it.
  The model doesn't own any other write.
- If the idea is deleted while the dossier is open (sync, or Wendy's phone), it shows `ContentUnavailableView` rather than
  stale content.
- Model tests live in `GalavantTests` against the in-memory database. A new test file means `xcodegen generate`, with
  `project.yml` and the pbxproj committed (see `verification.md`).

## Part 3. The view

`IdeaDetailView` becomes the dossier: `IdeaDetailView(ideaID:stopContext:whyOnTrip:onEdit:)`. It owns its
`IdeaDossierModel` as `@State`. `stopContext` and `whyOnTrip` stay host-supplied, since only a trip knows them. `onEdit` is
optional: Ideas passes it, and Trip and Today don't, which keeps their behavior unchanged.

Section order, top to bottom. The order is pinned so the read comes first. The exact styling is the executor's call.

1. Header photo, full width, display quality.
2. Identity: the existing kind, address/region, and phone header, then a visited check when set.
3. **Accolades, then interest, then taste notes**, or **notes, then accolades, then interest** when `emphasis ==
   .notesFirst`.
   - Interest lists each planner's level, with `InterestMenu` for mine. The match pill shows when `standing == .match`.
   - Taste notes list newest first, each with who and when. **Add Taste Note** opens the existing `TasteNoteEditorSheet`,
     with the idea preselected. Editing a note stays in Settings → Taste Notes and the idea form.
4. Description, then the trip-only sections ("On the Itinerary", calendar booking details, "Why it's on this trip").
5. Photos: a horizontal strip of thumbnails, skipped when there are none. A tap shows that photo's display bytes full
   screen.
6. Hours and weekly hours, then the map with Open in Maps, the website link, tags, and the idea's own notes.

**Presentation from Ideas.** One new `IdeasListModel.Destination` case, `.dossier(Idea.ID)`, set by `ideaTapped` for both
row and pin taps. Capture (`addIdeaButtonTapped`, `mapPlaceTapped`) still opens the form.

- **Compact:** push onto the existing stack with `navigationDestination(item:)`. Don't add a stack.
- **Regular:** the dossier **takes the list column's place**, and the map stays beside it with the idea's pin selected. A
  back control in the column returns to the list at the same scroll position. That's an overlay swap inside the column, not
  a nested `NavigationStack`: a stack nested in the split view's detail breaks navigation on iPad, which is why Trip's
  planning panel swaps its content instead. Leaving the dossier clears `focusedIdeaID` only if the list didn't
  set it.
- **Edit** is a toolbar button that sets `.form(...)` with the idea's draft, the same presentation a row tap opens today.
  Saving or cancelling returns to the dossier, which re-reads through its fetches.

Trip and Today keep their popover and sheet. They pass `ideaID` in place of the resolved arrays.

## Tests

**Package (`GalavantSchemaTests`):**

- `IdeaDossier` on a fixture with two planners, one rated, and one duplicate interest row: every planner is listed, the
  pending one with nil, and the duplicate converges.
- `standing` matches `Interest.standing` for match, neutral, and passed.
- Accolades: current before historical, and an orphan evaluation drops, the same as `currentAndHistorical`.
- Emphasis is `.notesFirst` for `.stay` and `.accoladesFirst` for `.food`, `.sight`, and nil.
- Notes are this idea's only, newest first. A note with this `ideaID` survives after the idea's tags and interests are
  gone.
- Photos exclude the header, keep `sortRank` order, and carry no display bytes.

**App target (`GalavantTests`):**

- `IdeaDossierModel` for an idea with three notes, while another idea has two: it reads exactly three.
- `setMyInterest(.mustDo)` writes one `IdeaInterest` for the current planner, and the dossier's interests reflect it after a
  load.
- With a header row present, the header bytes are that row's `display`, not its `thumbnail`.
- `IdeasListModel.ideaTapped` sets `.dossier(id)`, and `mapPlaceTapped` still sets `.form`.

## Out of scope

- The region guide, cards, and any `doNotDo` filtering (S3).
- Opening the website in the in-app browser, or field capture from the dossier. The link keeps opening Safari. S3 may raise
  it.
- Editing anything other than my interest and adding a note, inline in the dossier.
- Trip and Today getting an Edit button.
- Recommendation records (S4) and any "what happened" field (ADR OQ3).

## Done when

- A row or pin tap in Ideas opens the dossier on both platforms, and Edit reaches the existing form.
- Trip and Today render the same view from `ideaID`, and no host resolves dossier arrays itself.
- Every test above is green, and the existing Ideas, evaluation, and taste-note tests pass unchanged.
- `scripts/check-drift.sh` passes, and the app-target tests ran headless and passed (`verification.md`). Compile only, with
  no simulator walkthrough.
- The closeout carries this gate, word for word, with `--gate`:

  > **Idea dossier (`idea-dossier`).** On the iPad, then the iPhone, TestFlight build. In Ideas, tap a restaurant with a
  > Michelin rating, photos, and a taste note: the dossier opens, not the editor, with the header photo sharp and the
  > accolade, both of your interests, and the note above the fold. On the iPad the map stays beside it with the pin selected,
  > and Back returns to the list where you left it. Tap a map pin: same dossier. Tap a hotel: its notes lead. Set your interest
  > from the dossier, and the Ideas row shows it after Back. Add a taste note from the dossier: it appears there and in Settings
  > → Taste Notes. Tap Edit, change the description, and Save: the dossier shows the change. Open a photo from the strip: it
  > shows full screen. In a trip, open a stop's info: the same dossier, with "On the Itinerary" and a sharp header. Ask Wendy
  > to rate something you have open: her level arrives without reopening.
