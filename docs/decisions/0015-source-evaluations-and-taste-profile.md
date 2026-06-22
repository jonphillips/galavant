# ADR-0015: Source evaluations as a sibling record; a taste profile for prompts

*Status: accepted — 2026-06-22*

## Context

Two adjacent needs from the 2026-06-22 AI design chat (M6b):

1. **Professional evaluations.** Jon wants to keep *what a source said* about a place
   — Michelin `★★★`, an Andrew Harper `96/100`, a Forbes Five-Star, a World's 50 Best
   `No. 12`, or his own `Anchor` — and have a shared Michelin/Harper page populate it
   on capture. The sources use **incompatible judgment systems**; a star is an
   accolade, a Harper score is a 0–100 number, a list is a rank.
2. **A taste profile.** A short, editable preference description ("luxury, high-end
   dining, low-friction, characterful countryside") surfaced in the app and injected
   into every model call, so AI features reflect *this couple's* taste.

A ChatGPT artifact ("Travel App Source Evaluations Model") proposed a three-layer
model (canonical entity → source-native evaluation → app-normalized interpretation)
with four tables (`source`, `rating_system`, `entity_evaluation`,
`evaluation_aspect`) and a polymorphic `entity_type`/`entity_id`. This ADR adapts
that to Galavant's reality and **deliberately simplifies it**.

Two facts shape the adaptation:

- **Galavant already has one canonical entity: `Idea`** (with `kind: IdeaKind`),
  not separate `Hotel`/`Restaurant` tables. The artifact's polymorphism collapses to
  a plain `ideaID`.
- **Galavant already has an app-interpretation layer** — per-planner `IdeaInterest`
  (his/hers ratings, ADR-0007) and the `Interest.standing` *match* projection. A
  professional evaluation is a **third, distinct input**, not a replacement for that.

The spine (ADR-0014, the M6 strategy): AI and these records **preserve each source
natively and flag staleness — they never silently become the authority**. The
artifact's own rule ("the LLM is not the source of truth for ratings; do not invent;
flag stale data") is the same ethos.

## Decision

### 1. `IdeaEvaluation` — a sibling record, native-faithful, one table

A source's judgment about a pool idea is a sibling **`IdeaEvaluation`** record — the
`TripStay` shape (ADR-0011), not new columns on `Idea` and not a polymorphic
association.

```swift
@Table public struct IdeaEvaluation: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var ideaID: Idea.ID            // loose, optional FK (ADR-0007); orphan-drops on read
  public var travelPartyID: TravelParty.ID  // the one real FK (rides the party tree, cascades)

  // --- what the source said, in its own terms (preserve exactly) ---
  public var sourceName: String         // "Michelin Guide", "Andrew Harper", "Jon"
  public var kind: EvaluationKind       // stars / numericScore / rank / badge / recommendation / mention / personal / text
  public var nativeValueText: String    // "3 stars", "96", "No. 12", "Recommended"
  public var nativeValueNumber: Double? // 3, 96, 12 — for sort/filter only
  public var nativeValueMax: Double?    // 3, 100, … when bounded
  public var nativeDisplay: String      // "★★★", "96/100", "No. 12" — what the UI shows

  // --- provenance & time (so stale data can't masquerade as current) ---
  public var evaluationDate: Date?      // when the source judged (a 2018 Harper review)
  public var guideYear: Int?            // annual-guide year (Michelin 2025)
  public var recordedAt: Date           // when we captured it
  public var lastVerifiedAt: Date?
  public var confidence: EvaluationConfidence  // official / manual / imported / inferred / unverified
  public var staleness: EvaluationStaleness    // current / historical / stale / unknown
  public var sourceURL: String?
  public var summary: String?           // our own / generated private note about the rating
}
```

Key choices, each a simplification of the artifact for a two-person CloudKit app:

1. **One table, not four.** `source` and `rating_system` collapse into `sourceName`
   + `kind` + the native fields. Every table is a CloudKit record type; we mint the
   fewest that carry the meaning. Promote `Source` to a first-class table only if
   managing sources as entities ever earns it (it doesn't yet).
2. **No polymorphism.** One canonical entity (`Idea`) means a loose optional
   `ideaID`, reconciled on read exactly like `TripStay.ideaID` — orphans (idea
   deleted) drop when the read-model is built (ADR-0007). The real FK is to
   `TravelParty` (single-FK rule), so an evaluation is a leaf on the party tree and
   cascades with it.
3. **Native-faithful only for v1 — defer the normalized layer.** We store and show
   what each source said; we do **not** add the artifact's `normalized_score` /
   `normalized_band` (`anchor`/`destination`/`skip`). Reasons: it would be a *third*
   rating vocabulary alongside professional-native and the his/hers `Interest` scale
   (a confusion magnet), and the artifact itself warns sources aren't commensurable.
   When a screen genuinely needs one sortable planning priority, add the band then.
   Likewise **defer `evaluation_aspect`** (per-aspect service/setting/food scores)
   until a real use appears.
4. **Both `nativeValueNumber` and `nativeDisplay`.** The number drives sort/filter
   ("Michelin-starred first"); the display string is what humans read (`★★★`). Stars
   are an accolade, not a percentage — a 2-star is not "66% of" a 3-star, so the
   number is for ordering within a source, never cross-source math.
5. **Provenance + staleness are kept** (they're part of native fidelity, not the
   deferred normalization): a Harper `96/100` from 2018 is high-`confidence` but
   `historical`. The model layer (M6c) is instructed to prefer current/official over
   stale and to *flag* staleness, never silently rely on it.
6. **Lifecycle: born, not pulled.** An `IdeaEvaluation` is created directly — by
   capture extraction (M6c) or manual entry — like `TripStay`, never traveling the
   `considering → shortlisted` pull lifecycle (ADR-0004). Many sources → **many
   evaluations per idea**; this is a one-to-many leaf, no uniqueness constraint.

### 2. Distinct from his/hers `IdeaInterest` — a third input, not a merge

Professional evaluations and personal ratings answer different questions and stay
separate records:

- `IdeaEvaluation` = *"this external source judged this place this way."*
- `IdeaInterest` (ADR-0007) = *"how much do Jon and his wife each want this?"* — the
  existing per-planner scale + the `Interest.standing` match.

They are **not** reconciled into one number in v1. Both (plus the taste profile) are
fed to the model as *context* when it recommends or explains; the recommendation
layer is later work, not this ADR.

### 3. `TravelProfile` — the editable taste prompt, shared + per-planner

A small record holding free-text preferences, injected into model calls through the
`ModelClient` boundary (ADR-0014).

```swift
@Table public struct TravelProfile: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var travelPartyID: TravelParty.ID  // the one real FK
  public var plannerID: Planner.ID?         // loose, optional — nil = the shared household profile
  public var preferences: String            // "Luxury, high-end dining, low-friction, characterful countryside…"
}
```

- **Shared + per-planner overlay** (the 2026-06-22 decision). `plannerID == nil` is
  the household profile; a set `plannerID` is that person's overlay. Request
  construction assembles the system prompt from the shared profile plus the relevant
  overlay(s) — so a prompt can carry "Jon skews luxury/dining, his wife skews food"
  — which is also the structured taste seed for the future **match-prediction** bet.
- **Per-planner is a *subject* dimension, not access control** (ADR-0003 intact). A
  `TravelProfile` row is travel-party-shared content — both spouses see and can edit
  every row, no ownership flags — exactly as `IdeaInterest` holds per-planner ratings
  in shared records. "Per-planner" means *whose taste it describes*.
- One real FK → `TravelParty`; `plannerID` is the loose optional (ADR-0007).

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **Per-source columns on `Idea`** (`idea.michelinStars`, `hotel.harperScore`) | Rejected — the artifact's central warning. Schema sludge; bakes every source's idiosyncrasy into the canonical entity; a new source means a migration. |
| **The artifact's 4 tables + polymorphic `entity_type`/`entity_id`** | Rejected for v1. Over-normalized for two users on CloudKit (4 record types to sync); the polymorphism is pointless with a single `Idea` entity. The artifact itself blesses the MVP collapse. |
| **Reuse `IdeaInterest` for professional ratings** | Rejected. Different meaning (external accolade vs household preference), different scale per source, and it would pollute the his/hers *match* projection (ADR-0007). |
| **Add the normalized band now** | Deferred. A third rating vocabulary with no screen that needs it yet; native-faithful + model-as-context covers v1. Add when one sortable planning priority is actually required. |
| **Sibling `IdeaEvaluation` + `TravelProfile`, native-faithful (chosen)** | Faithful to each source, minimal CloudKit footprint, reuses the settled `TripStay`/single-FK pattern, and keeps the existing his/hers layer clean. |

## Relationship to prior decisions

- **ADR-0011 (sibling `TripStay`):** same shape reused — one real FK to the party
  tree, a loose optional `ideaID`, orphan-drops on read, born-not-pulled.
- **ADR-0007 (single-FK / loose-optional / per-planner):** honored — real FK to
  `TravelParty`, loose optional `ideaID` / `plannerID`; `IdeaEvaluation` and
  `TravelProfile` are new leaves. Per-planner-as-subject mirrors `IdeaInterest`.
- **ADR-0004 (pull lifecycle):** evaluations opt out, like `TripStay` — created
  directly, no `considering → shortlisted`.
- **ADR-0003 (everything party-shared):** upheld — both records are shared content;
  the per-planner profile is a subject dimension, not ownership.
- **ADR-0014 (model access):** the `TravelProfile` is injected at the `ModelClient`
  boundary; `IdeaEvaluation` is the structured context the model reads (and, in M6c,
  extracts into). The model never invents a rating — it preserves the native value.

## Consequences

- **Two new tables + CloudKit record types** (`IdeaEvaluation`, `TravelProfile`),
  additive migrations, single real FK each — sync-friendly like `TripStay`.
- **Read-model:** `TripPlan`/idea projections gain `evaluations(forIdea:)` (and a
  current-vs-historical helper) reusing the orphan-drop reconciliation; the detail
  view shows source-native ratings faithfully (`Michelin: ★★★`, `Andrew Harper:
  96/100`, `Jon: Anchor`) plus last-verified/confidence — **not** a single
  normalized score.
- **Capture (M6c)** extracts shared ratings pages into `IdeaEvaluation` via the model
  layer; manual entry is the other path. Both stamp provenance + staleness.
- **`TravelProfile` editing** lives in the settings/"You" area (the BACKLOG item) and
  feeds every AI call through ADR-0014's boundary.
- **Open at build:** exact `EvaluationKind` / `EvaluationConfidence` /
  `EvaluationStaleness` case sets; whether `nativeValueText` or `nativeDisplay` is the
  single required display source; the detail-view layout for multiple evaluations on
  one idea.
