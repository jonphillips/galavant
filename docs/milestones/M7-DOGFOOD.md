# M7 Calendar Reconciliation — Device Dogfood Script

The device gate for M7 (ADR-0034). Run it before Slice 7 flips the ADR to
**accepted** — the whole slice sequence was designed so nothing is declared
validated until real shared-calendar behavior is proven on device.

Two real iPhones on the same iCloud household are ideal. One phone covers
everything except the two-device convergence checks (I, R6); a simulator can
stand in as the *second* peer there but not as the calendar-editing device (a
shared iCloud calendar in EventKit is the one thing a simulator can't reliably
reproduce).

Each step is **action → expect**. Report the step number for anything that
diverges.

## Preconditions

1. Both phones signed into the shared iCloud; travel-party share already
   accepted (the independent M5 gate).
2. A **shared iCloud** calendar both people see (e.g. "Family"). **Not** an "On
   My iPhone" local calendar — a local event has no stable `externalIdentifier`,
   so it will never become a constraint or a shared outcome, and you'd be
   debugging a non-bug.
3. A **dated** trip in Galavant with a real **region** set (so the destination
   time zone resolves), e.g. Rome, Sept 14–17.
4. Trip → Calendar Reconciliation sheet → grant **Full** Calendar access → pick
   the shared calendar under "Calendar to Read."

---

## Part 1 — Ingest, match, constraints (Slices 1–5)

### A. Constraint appears (create)
Add **"Call Tax Advisor," Day 2, 10:00–11:00**, no location, on the shared
calendar → Refresh.
**Expect:** it appears under **"No Itinerary Match,"** and a
`calendar.badge.clock` row **"Call Tax Advisor 10:00–11:00"** shows on **Day 2**
of the itinerary (full itinerary *and* the day-lens). Not a pool idea, not a map
pin.

### B. Edit title & time (authoritative refresh)
Rename it **"Call Accountant"**, move to **13:00–14:00** (same day) → Refresh.
**Expect:** the same row updates in place — no duplicate.

### C. Move within the trip
Move it to **Day 3, 09:00** → Refresh.
**Expect:** row leaves Day 2, appears on Day 3 at 09:00 — still one row.

### D. Move outside the trip *(fixed in PR #23)*
Move it to a date **two weeks after** the trip ends → Refresh.
**Expect:** the row **disappears from the itinerary** (no longer a current trip
constraint) and is **not** deleted from Calendar. Move it back into the trip →
Refresh → it **reappears on the correct day**, same row (healed via its stable
identity).

### E. All-day & free
Add an **all-day** "Tax filing deadline" on Day 1, and a separate **timed 10:00**
event whose **Show As** you set to **Free** (Edit → Show As → Free; timed iCloud
events only — all-day is always day-context) → Refresh.
**Expect:** all-day row sorts to the **top** of Day 1 (day context); the free
event shows a **"Marked free in Calendar"** detail line. Neither blocks time as
hard-busy.

### F. Recurring series, incl. all-day → timed *(fixed in PR #23)*
Add a **daily recurring** "Morning check-in" as **all-day** across the trip →
Refresh → confirm one all-day row per day. Then **edit the series to assign a
time** → Refresh.
**Expect:** each day shows a **single timed** row — **no** leftover all-day
duplicate. (Ghosts created before PR #23 won't auto-clear; delete and re-add that
series once.)

### G. Superseded by a real match
Add a Calendar event named for a restaurant already scheduled as a Day-2 stop
(set its location so Maps matches) → Refresh.
**Expect:** it links to the existing stop (High-Confidence / Potential Matches),
and does **not** also create a duplicate "No Itinerary Match" constraint.

### H. Delete — provenance deletion
Delete "Call Accountant" in Calendar → Refresh.
**Expect:** the constraint row disappears automatically, **no keep/remove
question** (Calendar-originated).

### I. Two-device convergence *(needs a second peer)*
Phone A: add "Dentist 15:00" → Refresh A. Phone B: open the same trip's sheet →
Refresh.
**Expect:** exactly **one** "Dentist" row on B (arrived via CloudKit), not two.
Delete on A → Refresh A then B → gone on **both**, no ghost.

### J. Safety invariants — must NOT delete
- **Permission loss:** Settings → Privacy → Calendars → Galavant → No/Read-only
  access → open sheet → **Expect** "Full Calendar access is unavailable…
  Galavant made no deletion or itinerary decision," and existing constraints
  **remain**. Re-grant → they reappear.
- **Calendar-selection loss:** deselect in the picker → **Expect** the "Select
  the one shared calendar" prompt, **no deletions**.
- **Wrong calendar:** add an event on a *different* shared calendar you didn't
  select → **Expect** it does **not** appear and nothing is touched.

### K. Relaunch durability
Force-quit, relaunch, reopen the trip → **Expect** synced constraints still
present (CloudKit domain state, independent of the device-local binding cache).

---

## Part 2 — Plan repair, anchors, freeze (Slice 6)

These build on a **linked reservation**: a Calendar event matched to a scheduled
stop (as in G), which the app treats as time-authoritative for that stop.

### R1. Clock-only edit raises NO repair
On a linked reservation, change the **time within the same day** → Refresh.
**Expect:** the stop's time updates (authoritative cache refresh), and **no**
"Plan Repair" row appears. A fact isn't a question.

### R2. Day move auto-applies AND asks
Move the linked reservation to a **different trip day** → Refresh.
**Expect:** the stop **moves to the new day automatically**, *and* a **"Plan
Repair"** row appears — "Calendar moved this commitment to another trip day.
Check the surrounding plan." — with a **Mark Repair Resolved** button. Calendar
owns the date; Galavant asks about the surrounding route.

### R3. Resolve is sticky and shared
Tap **Mark Repair Resolved** → **Expect** the row flips to a green **Resolved**
label and stays resolved across Refresh/relaunch. (Two-device: resolving on one
phone shows resolved on the other; it must not reappear unresolved.)

### R4. Moved-outside becomes a shared repair *(not a separate section)*
Move a **linked reservation's** event **past the trip's end date** → Refresh.
**Expect:** the itinerary stop is **kept unchanged**, and a **"Plan Repair"**
row appears — "Calendar moved this commitment outside the trip. Decide whether
to extend or replan." There is **no** separate device-local "Moved Outside This
Trip" section anymore (removed as redundant).

### R5. Start-day anchors (advisory)
With at least one linked reservation carrying a real date, open the **Start Day**
panel.
**Expect:** an anchor row — "Calendar anchors suggest M/D/YYYY for Day 1." Now
add a **second** linked reservation whose date implies a **different** Day 1 →
**Expect** the panel switches to "Calendar anchors **disagree** about Day 1" and
lists each anchor. The trip start is **never moved automatically** — it stays a
surfaced choice (ADR-0034 §8). *(Fiddliest step; skip if setup is awkward.)*

### R6. Freeze after the trip ends
On a trip whose **end date has passed**, open the reconciliation sheet →
**Expect:** a final reconcile runs, then a **"Calendar Reconciliation Frozen"**
state. After that, edit one of that trip's Calendar events → Refresh →
**Expect** the edit is **not** applied (Calendar authority has ended, §12).
- **Decoupled rollup check:** confirm freezing did **not** silently mark the
  trip's scheduled stops as visited/done — that rollup is a separate feature, not
  a side effect of a calendar read (PR fix on this branch).
- **Two-device:** the frozen boundary syncs — the other phone also reads the
  trip as frozen.

## Part 3 — ADR-0041 dogfood amendments

These checks cover the follow-ups added after the first constraint dogfood pass.
Run them with the same shared-calendar and Full-access preconditions above.

### A. Raw-title match and manual link

Create an event whose raw title exactly matches one unambiguous itinerary stop,
but whose Maps lookup returns no place → Refresh.
**Expect:** it is promoted to **High-Confidence** and the same durable linked
path is used. Create a title with two possible stops → **Expect:** it remains a
**Potential Match** until you choose the intended stop in the picker. Tap
**Link**, verify the stop becomes Calendar-authoritative, then tap **Unlink**.
**Expect:** the stop returns to its prior authority and the Calendar binding is
gone, its Calendar-derived pin and clock clear to **Anytime** on the same day,
and a subsequent refresh does not recreate the automatic link. Link it again
manually to confirm the suppression is cleared, then unlink it once more.

### B. Ignore and un-ignore

For an eligible unmatched event, tap **Ignore**.
**Expect:** it is absent from both the reconciliation proposals and itinerary
constraints, while its **Ignored** row remains available in the sheet, with no
"Reading shared calendars…" loading flash. Tap **Un-ignore** and **Expect:**
the cached event returns to reconciliation without an EventKit reread or
geocoding pass. Repeat with a proposed match and Link it; the same cache-only
reconcile should update the row immediately.

### C. Ignore safety and deletion evidence

While an event is ignored, revoke Calendar permission, deselect the calendar,
or make the event temporarily invisible through a calendar-source change.
**Expect:** the ignored row is retained and no shared constraint or ignored row
is deleted. Restore Full access and the selected calendar; the ignored row is
still present. Delete the event authoritatively from Calendar, refresh with Full
access, and **Expect:** only then may the ignored record be reaped (and only
when the device-local binding corroborates the confirmed deletion).

### D. Own-zone constraint display

On a trip whose default zone differs from the event's carried zone, create a
timed absolute event (for example, an Eastern-time flight while the trip is in
Central Europe) → Refresh.
**Expect:** the itinerary row keeps its canonical ordering key but displays the
event's own clock and abbreviation, such as **6:00P EDT–7:00P EDT**.

### E. Per-day time-zone override

On a multi-day trip, open a day header and use the separate **Set time zone**
control; do not change the day's region. **Expect:** only that day's zone tag
and floating-event interpretation change. Clear the override → **Expect:** the
day falls back to its assigned region zone, then the trip centroid when no day
region exists. Remove all regions and confirm the centroid fallback still
resolves from the itinerary's stop coordinates; no device zone is silently
substituted.

### F. Calendar event notes

Add a note such as **"Bring the signed forms"** to an unmatched shared-calendar
event → Refresh so it becomes a Calendar constraint. Tap the constraint row in
the itinerary.
**Expect:** a detail sheet shows the title, event time, location when present,
and the full selectable notes text. Edit the Calendar note and perform a full
Refresh → **Expect:** the same deterministic constraint row shows the updated
note. A whitespace-only note has no notes affordance but can still show basic
event details when opened.

---

## Known deferred (don't file as bugs)

- **Resolution reopen race:** under sync lag two phones can briefly disagree on a
  repair's resolved state; it isn't a monotonic merge. Low-impact for two people.
- **Freeze boundary zone:** "is past" is computed in UTC while day projection
  uses the region zone, so the freeze edge can be off by the zone offset.
- **Pre-PR#23 moved-outside stop:** a stop that moved outside during earlier
  dogfooding may not produce a shared repair until the event is re-observed
  moving.
