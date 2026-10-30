# Handoff: ADR-0008 logical-uniqueness convergence (sync dedup hardening)

Close the open half of **ADR-0008**. SQLiteData's CloudKit sync supports **no unique
indexes** (only the primary key), so two devices editing offline can each insert a row
for the same logical key; both sync into a **logical duplicate**. Today Galavant has the
_code-level upsert_ half of the defense but **not** the _dedup-on-read + cleanup_ half.
This brief adds it for the three logically-unique tables and hardens the shared-party
identity race.

This is pure/near-pure functional-core work with a **proven reference implementation to
mirror** (see below) and a **testable** target — ideal for a high-effort autonomous run.

**Four phases. One PR is fine; sequence 1 → 2 → 3 → 4.** Phase 4 (identity, repoint-
before-delete) is the careful one — if anything is uncertain there, land 1–3 cleanly and
flag 4 for review rather than guessing.

---

## Shared context (read first)

Repo: galavant (V3) at `~/code/galavant/galavant`. Household iOS app, SwiftUI,
SQLiteData+CloudKit, no server, Point-Free style without TCA. Read `AGENTS.md` +
`CLAUDE.md` first. Conventions that will bite you:

- **Branch + PR workflow:** never push to main. Feature branch, open a PR.
- **Work in your OWN git worktree** (do not share the main checkout). Building from a
  worktree fails to resolve local SPM packages until you add this symlink:
  ```
  ln -s /Users/jon/code/jon-platform <worktree>/galavant/.claude/jon-platform
  ```
- **Almost all of this lands in the SPM package** (`GalavantLibrary/Sources/GalavantSchema`),
  which does **not** need `xcodegen`. Only the two read-model edits touch the app target
  (`Galavant/Ideas/IdeasListModel.swift`), and those are edits to **existing** files — so
  **no `xcodegen generate` is expected at all.** (If you add a new `.swift` file under
  `Galavant/` — the app target, not the package — you'd need to regenerate; you shouldn't
  need to. New files under `GalavantLibrary/Sources/…` are picked up by SPM automatically.)
- `swift test` **aborts here** (FoundationModels host gap): `GalavantPlacesTests` links FM
  and won't dlopen. Run the schema suite by temporarily disabling the FM-linked test
  target(s) in `GalavantLibrary/Package.swift`, or run `GalavantSchemaTests` from Xcode.
  None of this phase touches FoundationModels.
- Keep pure/derivable logic in the tested core as value types; no version suffixes in
  identifiers (ADR-0006). Match surrounding comment density/idiom.

### The spec and the reference implementation (read before coding)

- **Spec (the house law):** `jon-platform/docs/ios/persistence-and-sync.md`, **law 3**
  (~lines 102–119) and the multi-user identity section (~155–166). It states the whole
  pattern: code-level upsert + dedup-on-read, **survivor by a total stable order**,
  **repoint references to the survivor _before_ deleting losers**, let FK
  `ON DELETE CASCADE` clean children, and **keep non-owning read paths non-mutating**.
- **Reference implementation (mirror its shape):** Yes Chef already shipped this pattern.
  Worktree `~/code/cooking/yes-chef-import-duplicate-destructive-convergence`, branch
  `codex/import-duplicate-destructive-convergence`, commit "Prevent destructive import
  duplicate convergence":
  - `YesChefPackage/Sources/YesChefCore/RecipeRepository+Import.swift` — survivor ordering
    (~L673–679) and the convergence pass.
  - `YesChefPackage/Tests/YesChefCoreTests/LogicalUniquenessTests.swift` — the seeded-
    duplicate test suite to model ours on.
- **The ONE difference to get right:** Yes Chef orders survivors by
  `dateCreated → id.uuidString` because recipes carry a creation date. **Galavant's
  `IdeaInterest` / `IdeaTag` / `TripRegion` carry only `id: UUID` — no `dateCreated`.**
  So the total stable order here is **lowest `id` alone** (matches
  `TravelParty.ensureDefault`'s existing `order(by: \.id)`). **Do NOT add a `dateCreated`
  column** — that's a synced-schema migration, out of scope. Lowest-UUID is a complete,
  deterministic total order; every device independently lands on the same survivor.

### The three logically-unique tables (all in `GalavantSchema`)

| Table          | Logical key         | Fields (besides `id: UUID`)            | Has children? |
|----------------|---------------------|----------------------------------------|---------------|
| `IdeaInterest` | `(ideaID, plannerID)` | `level: Interest?`, `note`           | no (leaf)     |
| `IdeaTag`      | `(ideaID, tagID)`   | —                                      | no (leaf)     |
| `TripRegion`   | `(tripID, regionID)`| —                                      | no (leaf)     |

All three are **leaf rows with no children → no repoint needed** for their own dedup
(deleting a loser orphans nothing). Repoint-before-delete only matters in Phase 4
(`TravelParty`, which _does_ have children).

---

## Phase 1 — The pure convergence helper

**Goal:** one tested, pure helper that collapses logical duplicates deterministically, so
every read model and write path shares one definition (no re-deriving "first wins"
locally, which is order-dependent and can diverge between devices).

**Changes:** add a new file `GalavantLibrary/Sources/GalavantSchema/LogicalUniqueness.swift`
(new file in the SPM package — no xcodegen). Suggested shape (design latitude, firm
constraints):

```swift
extension Sequence {
  /// Collapse logical duplicates to one element per `key`, keeping the survivor with
  /// the lowest `id` — a total, stable order, so every device independently lands on
  /// the same winner (ADR-0008 / persistence-and-sync law 3). Pure: it does not delete;
  /// the owning write path deletes `losers` separately. Non-owning read paths use
  /// `survivors` only and never mutate.
  func convergingByKey<Key: Hashable>(
    _ key: (Element) -> Key
  ) -> (survivors: [Element], losers: [Element])
  where Element: Identifiable, Element.ID == UUID
}
```

Return **both** survivors and losers so read paths take `survivors` and write paths delete
`losers`. Keep it generic over `Identifiable where ID == UUID` (all three tables qualify)
— **not** hard-coded to a domain type.

**Acceptance (pure unit tests, `InterestMatchTests`-style, no DB):**
- Given rows with a duplicated key, `survivors` has one row per key; the survivor is the
  lowest `id`; `losers` is the rest.
- **Order-independence:** shuffling the input yields the same survivor set (the property
  that guarantees cross-device convergence).
- No duplicates → `losers` is empty, `survivors` == input (order preserved is fine).

---

## Phase 2 — `IdeaInterest`: read correctness + write cleanup

This is the phase with a **real correctness bug**, not just tidiness: a duplicated opinion
row is double-counted into the his/hers match projection.

**Context:**
- Read models (app target, `Galavant/Ideas/IdeasListModel.swift`):
  - `standingByIdea` (~`:229`): `Dictionary(grouping: interests.filter { $0.level != nil }, by: \.ideaID).mapValues { Interest.standing($0.map(\.level)) }`
    — feeds **every** level into `Interest.standing(...)`. Two synced-duplicate rows for
    the same `(idea, planner)` count that planner **twice**, which can manufacture or
    destroy a `.match`. **Bug.**
  - `ratingRow(for:)` (~`:220`): collapses per-planner with
    `uniquingKeysWith: { first, _ in first }` over **DB fetch order** — not a stable order,
    so two devices can show different levels under duplication.
- Write path (package, `GalavantLibrary/Sources/GalavantSchema/PoolOperations.swift:128`):
  `IdeaInterest.set(level:ideaID:plannerID:in:)` is already an upsert but does
  `fetchOne` on `(ideaID, plannerID)` — with duplicates present it picks an **arbitrary**
  existing row and leaves the others.

**Changes:**
1. **Read (non-mutating):** in `standingByIdea` and `ratingRow`, collapse interests to one
   row per `(ideaID, plannerID)` via `convergingByKey` **before** projecting. Use
   `survivors` only. **Do not delete here** — read models must stay non-mutating (Yes
   Chef's "destructive convergence" bug was exactly a read path that deleted; a preview or
   lookup must never delete user data).
2. **Write (owning path, the only deleter):** in `IdeaInterest.set`, fetch **all** rows for
   `(ideaID, plannerID)`, pick the lowest-`id` survivor, **delete the extra rows**, then
   apply the update/delete to the survivor. This is where losers actually leave the DB.

**Acceptance (seeded-duplicate tests, `@Suite(.dependencies { try $0.bootstrapDatabase() })`):**
- Seed **two** `IdeaInterest` rows for the same `(idea, planner)` by inserting drafts
  **directly** (not via `.set` — simulate two devices converging). Assert the standing
  projection counts that planner once (no phantom `.match`).
- Calling `IdeaInterest.set` on a seeded duplicate leaves exactly one row (lowest `id`),
  with the new level.
- Survivor is deterministic regardless of insertion order.
- A pure read of the seeded-duplicate DB (the standing projection) does **not** change row
  count — reads don't delete.

**Watch-outs:** `note` lives on `IdeaInterest` too — when deleting losers, don't silently
drop a non-empty note that only the loser carries. Simplest faithful rule: survivor is
lowest `id`; if you want to preserve a note, fold a non-empty loser note onto the survivor
before deleting (state whichever rule you choose in a comment + a test).

---

## Phase 3 — `IdeaTag` and `TripRegion`: cleanup passes

Reads of these are **already duplicate-safe** — both collapse through a `Set`
(`IdeasListModel.swift:63` / `TripPlanningModel.swift:291` build `Set($0.map(\.tagID))`;
`TripRegion.regionIDs` returns a `Set`). So there's **no read bug** here — the gap is only
that redundant rows **linger and sync forever**. Add a cleanup on each owning write path.

**Changes:**
- `IdeaTag` toggle/add path (`GalavantSchema/IdeaTag.swift`, the `exists`-guarded insert
  around `:21`): on write, converge `(ideaID, tagID)` and delete losers.
- `TripRegion.sync`/set path (`GalavantSchema/TripRegion.swift`, ~`:36–43`): converge
  `(tripID, regionID)` and delete losers as part of the sync write.

**Acceptance:** seed duplicate `IdeaTag` / `TripRegion` rows directly; after the owning
write, exactly one row per logical key remains; reads were already correct and stay so.

**Watch-outs:** keep these **on the owning write path only** — do not converge inside the
read projections (they're already `Set`-safe and must stay non-mutating). This phase is
tidiness/sync-hygiene, lower risk than Phase 2; keep it small.

---

## Phase 4 — Shared-party identity: prefer-shared, clean the empty stray (careful)

**Goal:** ADR-0008's identity half. Two devices offline can each create a "default"
`TravelParty` / default `Planner`; both sync. Converge to one **without stranding members**.

**Context:**
- `TravelParty.ensureDefault(in:)` (`GalavantSchema/TravelParty.swift:22`) already picks
  `order(by: \.id).fetchOne` — lowest-UUID, so the **survivor pick is already convergent**.
  What's missing: it doesn't **prefer a non-empty party** over an empty stray, and it never
  **cleans** the stray. If device A made a party and added members while device B made an
  empty one with a lower `id`, plain lowest-`id` would pick the **empty** one.
- `Planner.create(displayName:in:)` exists (used across ops and `PoolTests`).
- **Unlike Phases 1–3, `TravelParty` HAS children** — `Planner`, `Idea`, `Trip`, etc. hang
  off `travelPartyID` (some as real FKs, some as loose UUIDs per the single-FK sharing law).
  So this is the **one place repoint-before-delete applies**: before deleting a loser
  party, **repoint its members/content to the survivor**, then delete. Verify how each
  child references the party (FK vs loose UUID) before assuming cascade covers it —
  loose-UUID references are by-convention and won't cascade.

**Direction (design latitude, firm constraints):**
- Prefer the party that actually **has members/content**; only fall back to lowest-`id`
  among equally-populated (or equally-empty) parties — and that fallback must still be a
  **total stable order** so it's convergent.
- **Repoint children to the survivor before deleting the loser.** Do not rely on cascade
  for loose-UUID references.
- Preserve the "derived from data, resolves to the same party on every device" contract in
  the existing doc comment. Keep the identity direction consistent with the multi-user
  section of `persistence-and-sync.md` (Apple-ID / participant-keyed identity is the
  durable end state; don't regress it).

**Acceptance:** seed two `TravelParty` rows (one populated, one empty) directly; after
`ensureDefault` (or the dedicated convergence), one party remains, it's the **populated**
one, all members/content point at it, and the result is identical regardless of which had
the lower `id`.

**Watch-outs:** this is the fuzziest, highest-blast-radius phase (deleting a party with
children). If the child-reference topology isn't unambiguous, **land Phases 1–3 and flag
Phase 4 for Jon** with what you found rather than guessing a destructive convergence.

---

## Definition of done

- New `LogicalUniqueness.swift` helper, pure and generic, with order-independence tests.
- `IdeaInterest` standing/rating reads collapse duplicates (correctness); `IdeaInterest.set`
  cleans losers.
- `IdeaTag` / `TripRegion` owning writes clean losers; reads unchanged (already safe).
- (If not deferred) `TravelParty` prefers the populated party and repoints-before-deleting.
- Seeded-duplicate tests for each, all green in `GalavantSchemaTests` (run with the FM test
  target temporarily disabled, or from Xcode).
- No new synced columns; no `dateCreated` added; survivor order is lowest-`id` throughout.
- Read paths remain non-mutating; deletion happens only on owning write paths.
