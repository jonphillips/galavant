# ADR-0046: Device location is ephemeral, when-in-use, and asked for on use

*Status: accepted — 2026-09-11*

## Context

Galavant had **no location capability at all** until this decision: no
`CLLocationManager`, no `CLLocationUpdate`, no usage-description key, no
`UserAnnotation` anywhere in the tree. Standing on a hillside in the Dolomites
looking at the trip canvas, the one thing the map could not tell Jon was *where he
was standing* — every pin was a plan, none of them was him.

Adding the first location capability to an app is a privacy decision before it is a
feature decision, and it lands on an app whose whole persistence story
(ADR-0001, ADR-0003) is "everything in SQLite is shared with the travel party via
CloudKit." A device position is the one piece of data in this app that must never
enter that pipe.

## Decision

### 1. When-in-use only

The app requests **when-in-use** authorization and nothing else. It never requests
`Always`, declares no location background mode, holds no
`CLBackgroundActivitySession`, and registers no monitors, regions, or visits. There
is no use for Galavant knowing where its users are while it is closed; a travel app
that quietly tracks a couple's movements around Europe is not a thing we are
building.

Location is read through the modern `CLLocationUpdate.liveUpdates()` async sequence,
not `CLLocationManager` delegation. Starting that sequence is what implicitly takes
a when-in-use service session — which is also what prompts the user — and the
sequence's own diagnostics (`authorizationDenied`, `authorizationRestricted`) are
how the app learns it may not have location. Cancelling the consuming task ends the
session. This keeps "are we allowed" and "where are we" on one channel with one
lifetime, rather than a manager object whose authorization state outlives any view.

### 2. Never persisted, never synced

A device position is **ephemeral view state**. It is never written to SQLite, never
put in a `@Table` record, never registered with `GalavantCloudSync`'s `SyncEngine`,
and therefore never reaches CloudKit or the travel-party share (ADR-0003). It lives
in a view's `@State` for as long as that view is on screen and is gone when it
isn't.

This is a stronger rule than "we don't sync it today." Location is deliberately
outside the schema, so there is no table to accidentally add to the sync engine's
list later. A future feature that wants to *share* live position between the two
travel-party members is a separate ADR with a separate consent story, not an
extension of this one.

### 3. Asked for on use, never on launch or trip open

Authorization is requested the first time the user taps the location control on a
map. Not on app launch, not in onboarding, not when a trip opens. An unprompted
system permission dialog on opening a trip is the wrong first impression and trains
exactly the reflex ("deny, go away") we don't want.

The consequence is that the control has two forms: before authorization it is the
app's own "show my location" button, whose *purpose is* to trigger the prompt; once
authorized it becomes the system `MapUserLocationButton`, so follow-mode and heading
behave the way they do in Maps. Both occupy the same place in the map controls.

The usage-description string (`NSLocationWhenInUseUsageDescription`) is declared in
`project.yml` — the source of truth for the generated project — and is written as a
plain user-facing sentence, because Jon's wife reads it on her first launch.

### 4. Denied and restricted degrade silently

When authorization is denied, restricted, or Location Services are off globally:
no blue dot, no control, **no error state**. The map keeps doing everything it did
before. The app does not nag, does not explain, and does not deep-link to Settings.
A planning map that works perfectly well without location has no standing to
complain about not having it.

Restricted is treated exactly like denied at the UI: the distinction matters to us
(the user *cannot* grant it) but the correct behavior is identical — say nothing,
show nothing.

### 5. Location does not drive the camera

Device position is not allowed to fight the framing rules ADR-0012 established.
`frameSelection` and `revealStop` continue to frame the day lens and the selected
stop; neither consults the user's location. The only way the camera follows the
device is the user tapping the system location button, which is an explicit request.

The Today cockpit's day map (a separate slice) may *include* the user's position in a
union frame for the current day. That is a framing input on one surface, not a
general licence for location to move cameras.

### 6. Intent for "leave by"

Today's ETA and `leaveBy` machinery (ADR-0038, ADR-0039) is **allowed to read device
location later**, and should: "leave in 20 minutes" measured from where Jon actually
is beats the same number measured from the previous stop he has already wandered
away from. This ADR states the intent and does not build it.

The constraints it inherits are the ones above: the reading is ephemeral, the
computed ETA is not persisted as a trip fact, and the feature must produce a correct
answer from the previous stop when location is unavailable — location sharpens the
estimate, it is never load-bearing for the itinerary.

## Consequences

- The app layer gains a `LocationClient` dependency (a `Sendable` struct of
  closures with `liveValue`/`testValue`, per `docs/STYLE.md` §4) — no singleton, no
  `ObservableObject` location manager. Tests and previews get a deterministic stream.
- `NSLocationWhenInUseUsageDescription` enters `project.yml`; the regenerated
  `project.pbxproj` is committed with it.
- Nothing in `GalavantSchema` changes. Location has no schema presence by design.
- The trip canvas gains `UserAnnotation()` and a location map control; no other
  surface changes in this slice.

## Related

- ADR-0001 (CloudKit via SQLiteData) and ADR-0003 (one fully-shared travel party) —
  the sync pipe this data is deliberately kept out of.
- ADR-0012 (per-day region framing) — the camera rules location must not override.
- ADR-0038 / ADR-0039 (Today projections, execution) — the future consumer named in §6.
- `docs/trip-canvas.md` — the map surface this lands on.
