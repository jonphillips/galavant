# ADR-0040: Journey gains an image band — region "romance" photos (dual-source) and a selection-driven panel

*Status: **accepted** — 2026-08-16 (shipped on `feat/journey-refinements`). Fills the iPad
Journey header row's empty right side with a selection-driven image band, and adds a new
**region-scoped photo** (`RegionImage`) sourced from either Unsplash **or** the user's Photos
library. Extends ADR-0038's Journey surface (which stays read-only — an image panel is
presentation, not execution) and ADR-0032's trip "romance" header to regions. Preserves
ADR-0001 (no server), ADR-0007 (single-FK sharing), and ADR-0009 (image bytes are compressed,
syncable tiers).*

## Context

The Journey surface (ADR-0038, M10 J1–J3) lays out a fixed frame: a summary header, a stay
rail, a scrolling day spine on the left, and a held-still map on the right. Dogfooding showed
the header row's **right side is dead space** — the trip title, dates, and summary occupy only
the left third; the map lives in its own full-height column *below* the rail, not up here. That
empty band is prime real estate for making a trip *feel like its place*.

Three image needs surfaced, at three altitudes:

1. **Region** — when a stay is in focus, show the region it sits in ("Bavaria", "the
   Dolomites") as an ambient hero.
2. **Hotel** — the stay's own header image beside it.
3. **Stops, dinner first** — when a day is in focus, that day's stops as images, with a
   located meal floated to the front as the day's anchor shot.

Hotel and stop images already exist: they are `ImageAsset` header rows keyed by `Idea.ID`
(ADR-0009). **Region images did not exist.** `ImageAsset`'s own header comment flagged this —
region/trip "romance" imagery needs its own owner because the single-FK sharing rule (ADR-0007)
precludes one row FK-ing both an `Idea` and a region. ADR-0032 solved it for *trips* with a
lightweight hotlinked Unsplash reference on the `Trip` row. Regions needed the same idea — but
the product ask was broader: **choose from Unsplash *or* from my own Photos.**

## Decision

### 1. `RegionImage` — a region-scoped image table, bytes for both sources

A new table (not columns on `MapRegion`): `id, regionID (FK → mapRegions, ON DELETE CASCADE),
display, thumbnail, sourceURL?, photographerName?, photographerUsername?`. At most one per
region — `set(...)` deletes-then-inserts so a re-pick swaps rather than accumulates.

- **A separate table, not columns on `MapRegion`** — the same reasoning that keeps `ImageAsset`
  out of `ideas`: a region list/map query must stay light and never drag BLOBs. `MapRegion`
  rows stay small; the bytes live in `regionImages`.
- **Single FK to `MapRegion`** honors ADR-0007; the photo rides the region's travel-party
  CloudKit share through that edge and dies with the region (cascade).
- **Bytes for both sources**, unlike ADR-0032's trip hotlink. A Photos-library pick has *no
  URL*, so bytes are mandatory there; unifying Unsplash onto bytes too (download the selected
  photo → `GalavantImaging.ImageProcessing` → store `display`/`thumbnail`) gives **one storage
  form and one render path**, plus offline display. The trade-off — storing Unsplash bytes
  rather than hotlinking — is accepted; the Unsplash ToS obligations are still met (the
  `registerDownload` ping fires on selection, and attribution is stored and displayed).

### 2. `RegionPhotoPicker` — the dual-source picker (in `GalavantPlaces`)

A testable model owns search/download/process/store, mirroring `TripHeaderPicker`: Unsplash
search via the injected `UnsplashClient`; download via the injected `ImageFetcher`; process via
`ImageProcessing`; write via `RegionImage.set`. A Photos pick skips search and download — its
transferred bytes go straight to `process` + `set` with no attribution. The app hosts only the
thin sheet (an Unsplash grid, a `PhotosPicker`, and a source toggle).

### 3. The image panel — selection-driven, in the header's empty right side

`JourneyImagePanel` fills the header row's right side (never the map's column). Its content
follows the existing `JourneySelection`:

- **stay** → region card + hotel card
- **day** → the day's stops with images, dinner (`.food`) first
- **none** → the trip's opening region as an ambient hero

The region a stay/day belongs to is resolved by its explicit `TripDayRegion` assignment
(ADR-0012) when set, else by **geographic containment** — the first saved `MapRegion` whose box
covers the place — so a region photo attaches (and the "add photo" affordance appears) without
requiring the user to hand-assign day regions first. Tapping the region card opens the picker.

All panel imagery is the **thumbnail tier**, bounded in memory across a growing photo library.
Display-on-demand for crisper heroes is a deferred refinement.

## Consequences

- New synced table `regionImages` (migration "Create regionImages table (M10)", registered in
  `GalavantCloudSync` after `ImageAsset`). Device round-trip of the BLOB sync still to verify,
  as with `ImageAsset` (see [[sync-echo-yeschef]]).
- Galavant gains its **first in-app `PhotosPicker`** — previously all idea imagery arrived via
  web-scrape enrichment. The pattern is borrowed from Yes Chef.
- The `JourneyProjection.StopDigest` now carries `ideaID` so a stop can look up its image.
- Journey stays read-only (ADR-0038 restraint holds; only Today became executable, ADR-0039).
