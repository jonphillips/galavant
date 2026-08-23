# ADR-0032: Trip header image — Unsplash "romance" via a hotlinked reference on Trip

*Status: accepted — shipped end-to-end (picker + hero-band placement + `UnsplashClient`)
as of 2026-08-23. Realizes the BACKLOG "Trip header image — romance"
item (Jon, 2026-06-14) and the ROADMAP M5 "Unsplash header images" line. Governed by
ADR-0007 (single-FK sharing rule) and ADR-0009 (image storage); follows the injectable
I/O-boundary pattern of ADR-0018's `PlaceDiscoveryClient` ([[inject-io-boundaries-early]]).*

## Context

The trip screen feels stale. Jon wants a **selectable header image** so a trip *feels
like its place* — "feel like Copenhagen." The V1/V2 `galavantios` app had a tested
`UnsplashAPI`/`UnsplashSearch` module; the production Access Key from that app still
authenticates today (verified 2026-07-04: `HTTP 200`, 5000-req/hr production tier — the
demo tier is 50/hr), so the service and free tier are intact and no source swap is needed.

Two design questions decide the shape:

1. **Store pixels or a reference?** ADR-0009's `ImageAsset` stores *compressed bytes* and
   syncs them as CloudKit BLOBs, because idea photos are scraped from arbitrary sites that
   may vanish. Unsplash is different: it has a **stable CDN** and its API guidelines ask
   consumers to **hotlink** the image URLs rather than download/replicate them. A header is
   also **one image per trip**, not a gallery.

2. **Where does it attach in the synced schema?** The `ImageAsset` author already flagged
   this ([ImageAsset.swift](../../GalavantLibrary/Sources/GalavantSchema/ImageAsset.swift)):
   under ADR-0007's single-FK rule a row may hold **one** real foreign key, so an
   `ImageAsset` cannot FK both an `Idea` and a `Trip`. Reusing it for trip headers is out;
   the note offers "its own table or a loose-owner generalization."

## Decision

### 1. Store a reference on `Trip`, not bytes — no new table

Because we hotlink a stable CDN and need at most one header per trip, the header is a
**1:1 optional of small strings**. Add flat columns to `Trip` (which already flat-models
everything, ADR-0006):

```swift
public var headerImageURL: String?          // Unsplash urls.regular — the render URL
public var headerImageColor: String?        // hex placeholder shown while loading / offline
public var headerPhotographerName: String?  // attribution (ToS)
public var headerPhotographerUsername: String?  // attribution deep-link (ToS)
```

This is a **third option** the ImageAsset note didn't enumerate — available only because we
store a *reference, not pixels*. It **sidesteps ADR-0007 entirely**: no new FK, so no
"which parent does it ride the share through?" question. The columns ride `Trip`'s existing
CloudKit registration ([GalavantCloudSync.swift](../../GalavantLibrary/Sources/GalavantSchema/GalavantCloudSync.swift))
and reach the second device through `Trip → TravelParty` for free. `AsyncImage(url:)`
renders from Unsplash's CDN; offline (or pre-load) shows `headerImageColor`.

Escalate to a dedicated **`TripHeaderImage` table** (single FK → `Trip`, cloned from
`ImageAsset`'s bytes machinery) **only if** a later need appears for true offline pixels or
multiple saved candidates. Not now.

### 2. `UnsplashClient` — an injectable boundary in `GalavantPlaces`

A `Sendable` struct wrapping closures, `DependencyKey` live/`testValue`, `DependencyValues`
accessor — the exact shape of `PlaceDiscoveryClient` / `ImageFetcher`. It lives in
**`GalavantPlaces`** (where the network image clients already are); `GalavantImaging` is the
wrong home — that module is pure ImageIO, no network. Two verbs:

- **`search(query:perPage:) -> [UnsplashPhoto]`** — `GET /search/photos`, `Client-ID` auth,
  defensive decode (malformed → `[]`, like `PlaceDiscoveryClient.parse`).
- **`registerDownload(_ downloadLocation:)`** — fire-and-forget ping of the photo's
  `links.download_location`. **This is a ToS obligation, not optional** — Unsplash requires a
  tracked-download call whenever a photo is selected for use; skipping it risks the key.

`UnsplashPhoto` is a domain-light value type: `id`, `thumbURL`, `regularURL`, `color`,
`photographerName`, `photographerUsername`, `downloadLocation`. `testValue.search` returns
`[]` and `registerDownload` is a no-op, so the picker's parse/seed logic tests with no wire.

### 3. The Access Key is public config, not a BYO-key secret

The Unsplash **Access Key** is a public Client-ID designed to ship client-side — unlike the
frontier BYO-key path (ADR-0014, user's Keychain). So: no Keychain, no per-user entry, but
**not hardcoded in package source** either (house style). Inject it as a trivial
`unsplashAccessKey` string dependency read from an Info.plist key fed by an `xcconfig` build
setting. The verified production key from `galavantios` is reused — relocated out of source.

### 4. `TripHeaderPicker` — an `@Observable` in the package

Testable per [[inject-io-boundaries-early]]: seeds its query from the trip name / primary
`TripRegion`, calls `unsplashClient.search`, exposes `results`. On selection it **pings
`registerDownload` first** (ToS), then writes the four reference columns to `Trip` via the
tested DB. The app target owns only the thin grid sheet + the header view.

### 5. Attribution is mandatory, in the app UI

The header view overlays **"Photo by {name} on Unsplash"**, both the photographer and
Unsplash links carrying `?utm_source=galavant&utm_medium=referral` per the API guidelines.
Attribution display + the `registerDownload` ping are the two non-negotiables that keep the
production key in good standing.

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **Reuse `ImageAsset` for trip headers** | Impossible under ADR-0007 — a row can't FK both `Idea` and `Trip`. The schema note said so. |
| **New `TripHeaderImage` table storing bytes** (mirror ADR-0009) | Rejected for v1. Correct *if* we needed offline pixels or a gallery; we need one hotlinked reference. Heavier row, new sync registration, revives the M4 CloudKit-BLOB-sync verification cost for no benefit. Kept as the documented escalation path. |
| **Store bytes inline on `Trip`** | Rejected — drags BLOBs onto every trip-list query (the exact reason ADR-0009 split images into their own table) and fights Unsplash's hotlink guideline. |
| **Put `UnsplashClient` in `GalavantImaging`** | Rejected — that module is deliberately pure ImageIO (no network/persistence, ADR-0009 §2). Network image clients live in `GalavantPlaces`. |
| **Hardcode the Access Key in the package** (as `galavantios` did) | Rejected — even a public Client-ID stays out of package source; inject via build config. |
| **Skip `registerDownload`** | Rejected — it's a ToS requirement; omitting it jeopardizes the key. |
| **Reference columns on `Trip` + injectable `UnsplashClient` + `registerDownload` + attribution (chosen)** | Leanest correct fit: no FK tension, no new sync table, rides the share for free, ToS-compliant, and the picker is tested with a stubbed client. |

## Relationship to prior decisions

- **ADR-0007 (single-FK sharing rule):** storing a *reference* (no FK) sidesteps the rule
  the `ImageAsset` note ran into; the columns ride `Trip`'s existing share edge.
- **ADR-0009 (image storage/processing):** deliberately **not** reused — that path is for
  scraped, ephemeral, multi-image galleries needing offline bytes. `TripHeaderImage`-with-
  bytes is the documented escalation if that changes.
- **ADR-0014 (AI model access) / [[galavant-ai-cross-app-seam]]:** unrelated wire, but the
  same "domain-light value in, injectable boundary, `testValue` = empty" discipline.
- **ADR-0018 (`PlaceDiscoveryClient`):** the boundary shape is copied verbatim.
- **ADR-0006 (no version suffixes; flat Trip columns):** header fields are flat columns on
  `Trip`, plainly named.

## Consequences

- **GalavantSchema:** four optional columns on `Trip` (additive; no migration friction with
  SQLiteData's additive-column handling). No `GalavantCloudSync` change.
- **GalavantPlaces:** new `UnsplashClient` + `UnsplashPhoto`, the `unsplashAccessKey`
  dependency, and `TripHeaderPicker` (`@Observable`). Unit-tested with a stubbed client and
  an in-memory DB.
- **App target:** an `xcconfig`/Info.plist key for the Access Key; a header view on the Trip
  screen (`AsyncImage` + color placeholder + attribution overlay); a picker sheet
  (`swiftui-specialist` checkpoint).
- **Lift candidate:** `UnsplashClient` is domain-free stock-photo search — a jon-platform
  lift candidate (like WebExtractorKit / LLMClientKit) *if* yes-chef ever wants stock
  imagery. Per house style: inject now in `GalavantPlaces`, lift on the second consumer.

## Slices

- **Slice 1 — schema:** four `Trip` columns + `TripOperations` setter; in-memory DB test
  that a write round-trips and clears.
- **Slice 2 — the client:** `UnsplashClient` + `UnsplashPhoto` + `unsplashAccessKey`;
  decode test over a captured JSON fixture, `testValue` no-wire test.
- **Slice 3 — the picker:** `TripHeaderPicker` (`@Observable`) seed + select-writes-Trip +
  `registerDownload`-fired, all over the stubbed client.
- **Slice 4 — the UI:** header view + picker sheet on the Trip screen; attribution overlay;
  `swiftui-specialist` checkpoint; device install on the iPad Pro 13-inch sim
  ([[preferred-review-sim]]).
- **Slice 5 — docs:** flip to accepted; BACKLOG / ROADMAP.
