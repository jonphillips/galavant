# Effort — Calendar: a linked event that moves days shows as linked, and Plan Repair comes first

**Status:** Done (2026-10-08) · **Summary:** fixes the `KNOWN-ISSUES.md` entry *"a linked event
that moves days shows as 'No Itinerary Match' for one pass"*. A linked event is classified against its
linked stop, wherever the stop sits now. The actionable **Plan Repair** section moves above candidate
sections. Display only: the data was already right. No schema change, no sync change.

Implements ADR-0034 (calendar reconciliation authority) and ADR-0041 (dogfood amendments). Neither
changes.

## The bug

Observed 2026-10-07 on Jon's iPhone. Ruby was linked on Oct 19, then moved in Calendar to Oct 21. On the
Reconcile Calendar pass that sees the move:

- Ruby is listed under **No Itinerary Match**, with the footer "Eligible events are added as trip
  constraints". That's wrong twice: Ruby is linked, and linked events are excluded from constraints
  (`CalendarConstraintReconciliation.swift:101`).
- The stop still moves to Oct 21, and a `.movedDay` repair is created
  (`CalendarReconciliation.planRepairs`). The next pass lists Ruby under **High-Confidence Matches**.

**Cause.** `CalendarReconciliation.candidates`
([CalendarReconciliation.swift](../../GalavantLibrary/Sources/GalavantSchema/CalendarReconciliation.swift))
classifies each event against the itinerary as it was **before** this pass, and only against stops on the
event's projected day. Ruby's new day has no Ruby stop yet, so the result is `.unmatched`. Then
`automaticPlan` applies the move by identity (`linkedStopIndex` → `updateLinkedStop`). The sheet lists
the pre-application candidates.

## 1. Classify a linked event as its linked stop

Pass the local link state into classification. A candidate whose event is linked
(`CalendarReconciliation.linkedStopIndex(for:in:)` finds it) and whose linked `stopID` resolves to a stop
anywhere in `plan.itinerary` classifies as a match **to that stop**, on any day. Only then does the
existing same-day ladder run. If the linked stop no longer resolves (it was unscheduled or deleted), fall
through to the ladder as today.

- **Seam.** Give `candidates(for:trip:plan:temporalContext:ignoredSourceIdentityHashes:)` a
  `linkedStops: [CalendarLinkedStop] = []` parameter. Pass `localState.linkedStops` from
  `CalendarReconciliationModel.reconciledCandidates`
  ([CalendarReconciliationModel+Ingest.swift](../../Galavant/Calendar/CalendarReconciliationModel+Ingest.swift)).
  `localState` is already loaded at the top of `reconcileUsing`.
- **Result shape: your call, within one rule.** The link must stay **evidence of identity, not a new
  match rung**. The suggested shape is `.automatic(stop, basis: .linkedEvent)`, with a new
  `CalendarMatchBasis` case documented as "already linked; identity, not name or place evidence". Then the
  sheet's existing High-Confidence section and the linked-row treatment (`CalendarReconciliationModel`
  line ~191 already asks `linkedStopIndex != nil`) both apply unchanged. If you choose a different
  shape, keep every existing `switch` over the result exhaustive and meaningful.
- **`automaticPlan` must not change behavior.** It already handles a linked event first, by identity, and
  `continue`s, so the new classification never reaches the new-link branch. Check
  `automaticStopCounts` too: counting the linked candidate's stop must not block or allow a new link that
  wasn't blocked or allowed before. The new-link guard already refuses a stop that is linked, so it
  shouldn't, but pin it with a test.

## 2. Plan Repair goes first

In `CalendarReconciliationSheet.candidateSections`
([CalendarReconciliationSheet.swift](../../Galavant/Calendar/CalendarReconciliationSheet.swift)), move the
**Plan Repair** section above the candidate sections. It goes directly after the frozen and empty states
and before **High-Confidence Matches**. It's the one section that asks the planner to act. Today it sits
under **Calendar History**, where a day move's repair is easy to miss. Its rows and actions don't change.
**Calendar History** stays last.

## Tests (package, `GalavantSchemaTests`)

Model them on the existing reconciliation suites.

1. **Day-move pass.** A stop is linked on day 1, and its event now projects to day 3, where there's no
   stop of that name. The candidate classifies as the linked match to that stop, not `.unmatched`.
2. **Same pass, plan unchanged.** For the fixture in test 1, `automaticPlan` produces the same `.updated`
   application, day number and `.movedDay` repair it produces today.
3. **Stale link.** The linked stop is no longer in the plan. Classification falls through to the
   ladder, giving the same result as with no link state.
4. **Unlinked events don't change.** Run an existing ladder fixture with an empty `linkedStops`
   (the default). It produces identical results.

## Done when

- One PR on branch `effort/calendar-linked-move-display`.
- `scripts/check-drift.sh` is green. Headless `GalavantTests` pass (`docs/verification.md`), because the
  sheet and model change.
- The completing PR:
  - deletes the **Calendar Reconciliation: a linked event that moves days…** entry from
    `docs/KNOWN-ISSUES.md`;
  - adds a DONE-LOG entry;
  - marks this brief Done in `docs/efforts/README.md`;
  - adds one line to `docs/device-passes.md`: *move a linked trip event to another trip day in
    Calendar, run Reconcile Calendar, and confirm it shows as a linked match (not "No Itinerary Match")
    with the Plan Repair at the top of the sheet;*
  - sets `docs/NEXT_UP.md` to exactly this block:

    ```
    # Next Up — Tag management + tags on Idea rows

    **Slices:** effort `tag-management` (one PR, branch `effort/tag-management`)
    **Briefs:** `docs/efforts/tag-management.md`
    **Done when:** per the brief's "Done when"; verification per `docs/verification.md`.
    **Owed:** Jon's device gates in `docs/device-passes.md` (not executor work).
    **Notes:** No schema change and no new synced column, so no Production deploy. Tag convergence
    deletes and repoints synced rows, so get the survivor rule exactly right. Start from a fresh `main`.
    ```
