# ADR-0001: CloudKit via SQLiteData instead of a custom server

*Status: accepted — 2026-06-10*

## Decision

V3 has no server component. Sync is iCloud/CloudKit through SQLiteData's built-in
CloudKit synchronization. SQLite remains the local source of truth.

## Why

The hand-rolled sync layer was the heaviest part of both V1 and V2 (Server* twin
models, custom GraphQL client, SyncManager/UploadManager, auth, login screens) and
both repos stalled mid-rewrite of it. It generated no user-visible features. With
exactly two users in one household, a server buys nothing.

This also deletes authentication entirely: the iCloud account *is* the identity.
No AuthenticationService, no Keychain credential flow, no login/registration UI.

## What it rules out

- Android and web clients, ever, without reintroducing a server.
- Public/community features (V1's browse boards, following, public profiles).
- Server-side logic of any kind.

All accepted: this is a household app for two.

## Constraints it imposes

- Paid Apple Developer membership required (Jon's may be lapsed — verify before the sync milestone).
- Synced tables must follow SQLiteData's CloudKit schema rules (UUID-style primary
  keys, sync-friendly constraints). Design the schema for this from day one.
- Sync debugging is eventual-consistency-on-real-devices; no server logs.
- Verify current SQLiteData API/version at milestone start rather than from memory —
  the library evolves quickly.
