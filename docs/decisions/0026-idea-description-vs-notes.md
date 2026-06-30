# ADR-0026: Separate `description` (page fact) from `notes` (user space); additive notes on merge

*Status: accepted — 2026-06-30*

## Context

Capture pulls a short descriptor off the page — the JSON-LD / `og:description` summary,
de-marketed — and, until now, stored it in `Idea.notes`. That conflated two different
things:

1. A **page-derived fact**: "Three-Michelin-star Nordic restaurant." The source wrote it;
   it's confirm-and-tweak like name/address/kind.
2. The **user's own free space**: "Apple Maps sends you to the service entrance — the real
   door is round back." The user writes it; it's theirs to grow.

Two concrete problems surfaced from using one field for both (ADR-0025 browser-capture
feedback):

- On the **re-capture / dedup merge path** (ADR-0019), `Idea.supplemented(...)` is
  fill-blanks-only and didn't carry `notes` at all — so a user who captured a page, then
  re-captured it to add a note via the tap-to-fill bar, **silently lost the note**.
- The single field read as a *subhead* (the page blurb) in the detail view, leaving the
  user nowhere that felt like "my notes."

## Decision

Split into two columns on `Idea`:

- **`description: String`** — the page-derived short descriptor. A fact: filled by capture
  and by the second-hop enricher, **fill-blanks-only** on a re-capture (never clobbers a
  value already present). This is what the JSON-LD/`og:description` text now populates.
- **`notes: String`** — the user's own free-text. **Additive** on a re-capture: a fresh
  capture *appends* to the existing notes rather than replacing them (`Idea.appendingNotes`
  — blank additions no-op, verbatim duplicates aren't repeated, new notes are separated by
  a blank line).

Directions / access quirks ("wrong entrance") live in `notes` — they're rare enough that a
dedicated field isn't worth it, and the user instinctively knows when a place is hard to
reach.

The capture confirm sheet and the idea form/detail show both fields; the confirm sheet's
Description footer states that notes are additive, never overwritten.

## Consequences

- New migration adds `description TEXT NOT NULL DEFAULT ''` to `ideas`; existing rows
  back-fill to empty (their page blurb stays in `notes` as the user's text — acceptable,
  since pre-split notes were de-facto descriptions anyway and the user can move them).
- `supplemented(...)` gains `description` (fill-blanks) and `notes` (additive) parameters;
  the capture merge path threads both, fixing the dropped-note bug.
- `description` is the one merge field that is fill-blanks; `notes` is the one that is
  additive. Every other fact stays fill-blanks-only (ADR-0019 §3 unchanged).
- Chat context and the chat search haystack now include `description` alongside `notes`.

## Alternatives considered

- **A typed taxonomy** (separate tagline / notes / directions fields). Rejected as
  over-modeled: directions are rare and fit in notes, and a third field earns its keep
  only if it drives distinct behavior, which it doesn't here.
- **Replace-on-merge for notes.** Rejected — the whole point is that the user's note must
  survive a re-capture; replacement reintroduces the bug.
