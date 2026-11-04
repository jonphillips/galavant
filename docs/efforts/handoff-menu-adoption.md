# Effort — Adopt the shared AI menu

**Status:** Blocked · **Summary:** Replace the trip's local AI toolbar menu with the shared `HandoffMenu` from
jon-platform. Blocked until Yes Chef's `handoff-menu` Part 1 merges the package, and on `hand-off-purposes` here. No schema,
migration, sync-contract, or handoff-contract change.

**Implements:** jon-platform `docs/ios/ui-and-platforms.md` § The AI entry point. That rule is the decision, so there is no
ADR here. The package work is dispatched from Yes Chef (`docs/efforts/handoff-menu.md`). The architect flips this brief to
Ready once the package PR merges and `hand-off-purposes` is done.

## The work

1. **`project.yml`:** add `LLMHandoffUI` (from the `LLMHandoffKit` package) to the `Galavant` target only. Regenerate the
   project.
2. **`TripPlanningView.swift`:** replace the toolbar `Menu` with `HandoffMenu`, using the several-purposes initializer. The
   purposes are **Get Recommendations** and **Summarize Conversation**, in that order. Paste calls the same model method it
   does today. Keep the single `ToolbarItemGroup` (`docs/KNOWN-ISSUES.md`).
3. **Ask now becomes the shared `Toggle`** bound to `showingChat`, which replaces the Button that swaps its icon to a
   checkmark. If `showingChat` opening and closing has a side effect in the old Button, carry it into the binding.
4. **`Icon.swift`:** delete `Icon.ai` and `Icon.askNow`, and delete `Icon.handoff` and `Icon.paste` if nothing else uses them.
   Sites that still show those glyphs use `HandoffSymbol`, not a string literal. `Icon.recommend` stays for Evaluate.

**Out of scope:** the other `sparkles` uses (Evaluate, the map's fuzzy pins), and bringing chat back to the Ideas screen.

**Verification:** `scripts/check-drift.sh` and the app build, per `docs/verification.md`.

**Done when:** `TripPlanningView` has no local AI `Menu`, the app builds, and closeout runs (ADR-0005 D16), appending the
device gate below.

## Device gate (Jon)

On iPad and iPhone, on a trip: the toolbar menu reads AI with `sparkles` and the other trailing toolbar items are all still
there. Hand off opens a submenu with both purposes. Ask now opens chat, shows a checkmark while it's open, and closes it from
the same item.

## Merge

This owes a gate, so Jon merges it (ADR-0005 D9).
