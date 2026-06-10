# ADR-0006: Domain vocabulary

*Status: accepted — 2026-06-10*

## Decision

| Concept | Name | Replaces |
|---|---|---|
| Pool item (a possibility for some future trip) | **Idea** | V1 `Place`, V2 `Attraction` |
| Trip ↔ idea join (status lifecycle) | **TripIdea** | planned `TripAttraction` |
| Scheduled itinerary item | **Stop** | V1 `TripActivity`, V2 `Event` |
| Geographic bucket | **MapRegion** | unchanged from V2 |
| Trip, Itinerary, Shortlist, Tag | unchanged | — |

A `kind` enum on Idea (sight / food / stay / tour / activity / …, descendant of
V1's POICategory) carries the taxonomy; the entity name stays neutral.

## Why

- **Idea**: V2's broadening from Place to Attraction was the right instinct but
  the wrong word — meals, lodging, and experiences (e.g. a Context tour) aren't
  "attractions" in plain English. "Idea" matches the actual mental model
  ("collect possibilities for Denmark"), covers every kind without strain, and
  reads naturally in household conversation and in the join name.
- **Stop**: travel-native and collision-free. `Event` collides with EventKit,
  `Activity` with NSUserActivity/Live Activities.
- **MapRegion** (not "Destination", despite V2's `toggleDestinationInFilter`
  leak): `Destination` is reserved by the swift-navigation pattern — every
  feature model has a `Destination` enum.

## Open (decide at M3)

Whether Stop is the TripIdea join wearing the `Schedule` enum, or a separate
entity. Standalone itinerary items with no pool idea (flights, transfers,
"drive to Aarhus" — V1 had these as placeless TripActivities) are the case that
may justify a separate entity.

## No version suffixes in the namespace

The product is **Galavant**, full stop. Repo dir (`~/code/galavant/galavant`),
Xcode project, app/target/scheme names, SPM package, module names, bundle ID,
app group, and CloudKit container are all plain `galavant`/`Galavant` — never
`V3`, `3`, or any rewrite marker. "V1/V2/V3" exists only in docs as history
(prior repos: `galavantios`, `galavant-v2`). Use a **fresh bundle ID** rather
than reusing V1's, so no App Store Connect / provisioning baggage carries over.

## Hygiene rule

Entity and column names get spell-checked before landing in the CloudKit schema
(V1 permanently shipped `AuthenitcationSM`, `MutliSelector`, `instragram_url`).
Typos in synced schemas are forever.
