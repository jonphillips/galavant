# ADR-0009: Image storage & processing

*Status: accepted — 2026-06-16. Promotes the cross-cutting image strategy that
had been living as ROADMAP (M2) intent + BACKLOG ("Portfolio extraction seams")
notes into a settled decision, before M2 images / M4 scraped images / M5 Unsplash
headers start leaning on it.*

## Problem

Images arrive from three sources, all converging on the same need — store +
CloudKit-sync a picture attached to an `Idea` or `Trip`:

1. **M2** — user-selected (Photos picker) on the capture form.
2. **M4** — scraped from a shared page (OpenGraph/`og:image`, share extension).
3. **M5** — Unsplash header images on the trip canvas ("romance").

ADR-0001 already removed the server: there is **no S3, no UploadManager** (the
component that stalled V1/V2). So images must live in CloudKit. CloudKit imposes
constraints the usual "just store the bytes" answer ignores:

- A `CKRecord` **field has a ~1 MB cap**; large binaries belong in a `CKAsset`
  (file-backed, synced out of band).
- Every synced byte costs sync time/quota and bloats the rows it rides on.

## Decision

### 1. CloudKit-native only — no S3, no server

Reaffirms ADR-0001. Reopening S3 / a separate object store requires a **new ADR**;
it is not a default to reach for. iCloud is the only backing store.

### 2. Split *processing* from *storage*

- **Processing** is pure: `Data`/image → a resized/compressed display image + a
  thumbnail. It imports **no SwiftUI, no CloudKit, no persistence** — just
  Foundation/CoreGraphics/ImageIO. This makes it unit-testable with bytes and is
  the clean **portfolio-extraction candidate** (BACKLOG "Portfolio extraction
  seams"): the same resize/compress/thumbnail is useful to a future app.
- **Storage** is stack-specific (SQLiteData + CloudKit table) and stays in the app
  / schema package. It travels to another app only if that app also uses
  SQLiteData + CloudKit.

The two never entangle: processing must not import the persistence layer.

### 3. A dedicated image table, single-FK per ADR-0007

Images live in their **own table** (e.g. `ImageAsset`), not as columns on `Idea`/
`Trip`, so those rows stay light and don't drag image bytes on every fetch/list/
map query. The table carries **one real FK to its owning shared record** (the
`Idea` or `Trip` that rides the travel-party share — ADR-0007's single-FK rule),
plus provenance fields (source URL; Unsplash author + link for the required
attribution).

### 4. Two tiers; default to the display tier

- **Display tier (the default, ships first):** resize on import to ~**1600 px**
  longest edge, compress (HEIC/JPEG) to ≈**300 KB**, store as an **inline BLOB**.
  Comfortably under the ~1 MB `CKRecord` field cap, so it syncs as a normal record
  field. This is what the UI renders; for a two-person app it is very likely
  *sufficient on its own*.
- **Thumbnail:** a small derivative for lists / map pins, also inline.
- **Full-resolution (deferred, optional):** only if a real need appears, store the
  original via **`CKAsset`** (file-backed, dodges the 1 MB field cap). **Gated on
  verifying current SQLiteData BLOB→`CKAsset` support first** — that area moves
  fast; do not assume it. Until then, the display tier is the canonical image.

### 5. The synced bytes are canonical; the decoded bitmap is a local cache

Only the compressed `Data` in the table syncs. The **decoded `UIImage`/bitmap is a
device-local cache** (e.g. `URLCache`/an on-disk cache) and is **never synced**.
Re-decode on device; never round-trip a bitmap through CloudKit.

### 6. One import path

All three sources funnel through the same pipeline: *source bytes → processing
(resize / compress / thumbnail) → store in the image table*. The source differs
(picker / scrape / Unsplash fetch); everything downstream is shared.

## Why this is an ADR and not just a milestone task

Image storage is **cross-cutting** — M2, M4, and M5 all inherit it — and the
constraints are architectural laws, not feature details: *no S3 (ADR-0001); the
~1 MB field cap forces resize-on-import + a dedicated table; full-res means
`CKAsset`, not a fatter field; processing stays pure and portable while storage
stays stack-bound.* Every future image feature inherits these. Recording it now
keeps the three milestones from each re-deciding it (and from quietly reaching for
S3 when the cap bites).
