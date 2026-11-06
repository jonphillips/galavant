# ADR-0052: Chat assistants stage trip options into Evaluate through a local MCP server

*Status: **proposed** — 2026-11-04, ratified by Jon merging this ADR's PR. Effort:
[`chat-access`](../efforts/chat-access.md). Galavant is the third consumer of jon-platform ADR-0007 (app data over a
local stdio MCP server) and, after Yes Chef's ADR-0060, the second app that uses its Amendment 1 (no Mac presence,
so the transport is iCloud Drive). The transport itself is shared through jon-platform ADR-0009 (`ChatAccessKit`).
Amends [ADR-0036](0036-recommendation-handoff.md) D4 for this door only, and gives
[ADR-0037](0037-recommendation-evaluation-workspace.md) D8 its second feed. Holds
[ADR-0004](0004-pull-based-trip-membership.md): the model proposes, and a human tap is the only write. No synced
schema change.*

Summary: In a ChatGPT or Claude chat, the model calls one tool to stage a set of travel options on a trip. A **From
Chat** row appears in Evaluate on any of Jon's devices, and one tap imports the set and opens it in the workspace.
Chats can start from a hand-off brief or, once the read tools land, directly in the assistant.

> **Vocabulary.** A **staged return** is one file in the iCloud Drive inbox: the same text a paste would carry, named
> for its trip. **Importing** is the tap that turns a staged set into `.considering` trip rows. **Travel options**
> here means what Evaluate already handles: places, including hotels as ordinary place candidates. Flights and trains
> have no home in Evaluate and aren't part of this.

## Context

Today a recommendation round trip has two manual crossings (ADR-0036): copy a brief out, then copy JSON back and tap
**Add to Considering** on each row. Only then does the set appear in Evaluate, because `EvaluateQueueModel` lists only
sessions with at least one linked trip row.

Yes Chef removed its return crossing in the past 48 hours (ADR-0060 and Amendment 1), and its device passes taught
four things Galavant inherits without paying for them again:

- A tool's description isn't enough to get it called. ChatGPT had `stage_handoff_return` and still printed its first
  return, so every routed prompt now says to use the tool.
- Models drop the contract line even when the tool description spells it out. Two returns came through without it.
- One conversation can produce several returns, and keeping only the newest can lose one unseen (Yes Chef ADR-0061).
- The Mac evicts container files, and colons in file names arrive on iOS as slashes.

The jon-platform review of Nov 3 also reached a conclusion that shapes this ADR: going from the app to ChatGPT is the
crossing that keeps going wrong, so most flows should be able to start in the chat and pull what they need through
tools, as Vinyl Fever does.

Three things differ from Yes Chef, and they're where this ADR spends its words:

1. **Evaluate has to change.** A staged item has to appear before anything is committed, and processing it has to
   skip the row-by-row sheet. Otherwise it doesn't "show up directly".
2. **Galavant can route with a synced ID.** Yes Chef's `AIHandoff` targets a device-local row, so only the minting
   device can open a return. Every Galavant return lands on a **trip**, and trip IDs sync.
3. **The helper can check the whole return.** Yes Chef's body parse depends on a task type stored on the device, which
   is a named gap against ADR-0007 D3. Galavant's two return shapes parse with no device state, so the gap closes.

## Decision

### D1 — A standalone `galavant-mcp` helper, built from `GalavantSchema`

The app is iOS only, so this follows ADR-0007 Amendment 1-D1. A macOS-only `GalavantMCP/` package depends on
`GalavantLibrary`, `MCPServerKit`, `LLMHandoffKit`, and `ChatAccessKit`. It stays out of the package graph the iOS app
resolves. `scripts/install-mcp-helper` installs it to `~/.local/bin/galavant-mcp`, and it runs under a `galavant`
tunnel profile on health port 8082 (`jon-platform/docs/ios/mcp-access.md`).

### D2 — The transport is the app's iCloud Drive container, through `ChatAccessKit`

The existing `iCloud.com.jonphillips.galavant` container gains the iCloud Documents service. It isn't published to
Files. `MCP/Inbox/` holds staged returns, `MCP/Inbox/Processed/` holds consumed ones for 30 days, and `MCP/Exports/`
holds read exports. Galavant Dev shares the container (ADR-0050 D3), so it uses `MCP-Dev/`, and the helper takes
`--variant dev`.

**Rejected: running Galavant on the Mac.** It would make a sometimes-asleep Mac a full sync peer, and Galavant's restore
is already a two-person event (ADR-0049 D2). Yes Chef ADR-0060 D2 gives the full argument, and it applies here.

**It only ever reaches Jon's devices.** A ubiquity container belongs to one iCloud account. Wendy's devices have their
own, and her Mac runs no helper. Options she sees are ones Jon imported, once they sync as ordinary trip rows.

**A device-local Chat Access switch in Settings gates all of it,** and it's off by default. When it's off, the app runs
no query, writes no export, and shows no iCloud warning. Jon turns it on for his iPhone and iPad.

### D3 — One write tool, and the helper checks the whole return before writing

`stage_trip_return(trip, text)`:

- **`trip`** is the trip's UUID (D4). **`text`** is exactly what the model would otherwise print for pasting.
- **One tool, for both return shapes.** The shape is recognized from the text with the same classifier the Paste button
  uses (`hand-off-purposes`), so the server's tool list can't drift from the app's verbs. Yes Chef Amendment 1-D2 made
  the same call.
- **The checks are the paste door's checks, in the same order and from the same Core code:** strip the optional
  `GV-HANDOFF` line, strip the marker, classify, and decode. A bad return comes back with `isError` and the reason, so
  the model corrects itself in the chat, not on an iPad an hour later. There's no second parser.
- **Amended 2026-11-06, one check this door adds.** `{"summary": …, "places": […]}` is both a valid seed and a candidate wrapper
  seen in real replies, and shape alone can't separate them. The helper has no device state to check, and the model knows which
  one it meant. So a return that has `places`, no `bases`, and no `GV-SEED` line comes back with `isError`, asking for that line
  (a seed) or a JSON array (candidates). The instructions ask for the line up front. Paste keeps its current behavior. Rejected:
  treating these returns as seeds, which would open a candidate set in seed review and save its summary as a trip document.
- **A newer contract marker is an error. A missing or older one is not, and it raises no warning** at this door. The
  decode is the real guard (ADR-0036 Amendment 1), and on Yes Chef's evidence a warning here would mostly be noise.
- **The file:** `HandoffInbox(root: …/MCP/Inbox, fileExtension: "gvreturn")`, slug = the trip UUID, content = the text
  unchanged. The app can name the trip before the file finishes downloading.
- **Annotations:** not read-only, not destructive, so ChatGPT asks first. That's the second checkpoint (ADR-0007 D3).
- **The result** says where it went: staged for review in Evaluate. The model says that, not "saved".

### D4 — Routing is by trip ID; the hand-off token only names the set

- **Any of Jon's devices can open any staged return,** because trips sync. There's no "Started on another device" dead
  end. Handing off from an iPhone and evaluating on an iPad is the normal case, since the workspace is built for the
  iPad.
- **Each brief carries a `GV-TRIP: <uuid>` line** after its token, and the finalize line tells the model to pass it as
  `trip`. It travels as a tool parameter and isn't part of the return, so **the paste contract doesn't change and the
  marker stays `v2`.** If a model echoes the line in pasted text, the door strips it.
- **ADR-0007 D5 holds.** The model needs this ID to route, and it gives no reach: the ID resolves only inside Jon's
  library, and only to a row he then taps. The same reasoning as Yes Chef Amendment 1-D1.
- **A token in the text names the set.** If this device has that session for this trip, the return merges into it, and
  that's how a second round in one chat joins the first. If not, the device makes a session **with the token's ID**, so
  later returns from that chat land in the same set. With no token, it makes a new one. The set then lives on the device
  that imported it, as a pasted set does today.
- **Unknown trip:** the row says the trip isn't on this device yet, and it offers **Copy** and **Discard**. A trip can
  still be syncing, so it never guesses another trip.

### D5 — A From Chat section in Evaluate; one tap imports the set

**This amends ADR-0036 D4's row-grain review for this door.**

- **The row appears as soon as the file arrives:** "Denmark · 8 options", with when it was staged, plus **Discard**. The
  Evaluate tab or sidebar item shows a badge. Nothing has been written yet.
- **The tap is the commit.** It writes every option as a freeform `.considering` `TripIdea` through the existing
  `TripIdea.commit`, in one transaction, then opens the workspace on that set. Rationale goes to `inlineNote` and the
  pool stays clean, exactly as ADR-0036 D3 requires.
- **ADR-0004 holds.** The tap is a human gesture on a row that names the trip and the count. By then Jon has also
  confirmed the tool call. Each option still goes through the ADR-0037 processing loop, and Dismiss deletes with undo.
- **ADR-0036 D6 holds.** Placement refs stay advisory, and nothing writes an itinerary slot.
- **A prose note from the return** is saved as a `TripDocument` with the import, since there's no sheet to ask in.
- **The order is write, save session, then claim.** `TripIdea.commit` already returns the live row when a place is on the
  trip, so if the app dies midway, or two devices race, a retry links the same rows and creates no duplicates.
- **Discard** moves the file to `Processed/` and writes nothing to the trip.
- **The paste door and its row-by-row sheet stay as they are.** That sheet is still the place to edit a candidate before
  it lands.

### D6 — A staged seed opens seed review, not the workspace

`seedTrip` returns use the same tool and the same inbox. Their row reads "Denmark · Trip seed · 14 places". A seed is a
reviewed plan with stays, verdicts, and pool matches (ADR-0048), so the tap opens the trip and its existing seed review.
Nothing commits on the tap.

**A seed is claimed when its review commits, not when it opens.** Dismissing a long review shouldn't lose the narrative;
the row stays until it's committed or discarded.

### D7 — The contract travels with the server, and paste stays the fallback

- The server `instructions` are generated from `RecommendationHandoffContract.projectInstructions`, with an opening whose
  first 512 characters stand alone and name the tool (ADR-0007 D1 and D6). A chat with the plugin on needs no Project.
- Every brief says, right after its token and trip lines: call `stage_trip_return` if the chat has it, and otherwise
  start the reply with the `GV-HANDOFF:` line. Yes Chef's device pass is why this isn't left to the tool description.
- If the tool fails or times out, because the Mac is asleep or the tunnel is down, the model prints the return for
  pasting. Nothing is retired: the Hand off menu, Paste, and the Settings copy button all stay.

**Skills.** Plugin skills are untested for a personal tunnel plugin on iOS. If they work, the long seed format is the
obvious thing to move into one, and the tool, inbox, and D3 checks don't change. This ADR keeps that move cheap by keeping
all rules in one Core constant. It doesn't wait for the test.

### D8 — Read tools let a chat start in the assistant

`list_trips` and `get_trip(trip)` read a derived export, per ADR-0007 Amendment 1-D2.

- **`get_trip` returns what a brief carries,** from the same Core functions: notes, stops, stays, ruled-out places, and
  taste lines, plus current `.considering` and shortlisted titles, so the model doesn't re-suggest them. No images, no
  planner identities beyond what a brief already includes, and no sync metadata.
- **The trip's UUID is the reference.** Yes Chef's `<generation>.r<index>` refs protect against a stale index becoming a
  write target. Galavant's trip IDs are stable, the write only adds `.considering` rows, and the row names the trip before
  the tap. So Yes Chef's OQ4 concern doesn't apply, and a chat that starts in ChatGPT can stage directly.
- **Each device writes its own file** when the app backgrounds and from **Refresh** in Settings, throttled to one per 15
  minutes. Results report the export's age, and a newer format version fails loudly.
- **The export's read must not repeat the launch-lock crash.** It runs under a background-task assertion, off the main
  actor, and builds each trip's plan once, because `TripPlan` rebuilds on each access.
- Once the export exists, `stage_trip_return` also rejects a trip ID the export doesn't contain, with a message that sends
  the model back to `list_trips`.

### D9 — What's shared and what's Galavant's

| Shared | Where |
| --- | --- |
| Folder layout, container and helper paths, watcher, claim, retention, export read and write | `ChatAccessKit` (jon-platform ADR-0009, moved from Yes Chef) |
| Protocol loop and tool registry | `MCPServerKit` |
| Inbox files, contract marker, token routing | `LLMHandoffKit` |
| Tunnel ops and helper install | `scripts/mcp-tunnel`, `scripts/install-mcp-helper` |

**Galavant's own:** the tool and its checks (`StagedTripReturn`), rows, the bulk import, the export's shape, and the Evaluate
UI. Galavant's `HandoffSession` stays as it is, and the seam ledger's envelope row stays closed.

## Why this and not the alternatives

| Option | Verdict |
| --- | --- |
| **Keep the row-by-row sheet for staged sets** | Rejected: it's the step Jon asked to remove, and Dismiss with undo already handles a bad option. Paste keeps it. |
| **Auto-import on arrival, with no tap** | Rejected: ADR-0007 D3 and ADR-0004. Synced rows would reach Wendy from a tool call nobody reviewed in the app. |
| **Let the workspace run over uncommitted candidates** | Rejected: the workspace is built on trip-row IDs. It would need a second candidate model and a new draft state for one tap's saving. |
| **Route by token, as Yes Chef does** | Rejected: a device-local token strands the return on the device that handed off. Trip IDs sync, so the restriction buys nothing here. |
| **One tool per return shape** | Rejected: the tool list would restate the app's verbs and drift, and Yes Chef's two tools needed extra routing text (yes-chef #435). |
| **Typed candidate fields in the tool schema** | Rejected: a second shape beside the paste contract. The text form has one parser, and that parser's errors go back to the model. |
| **Export refs (`<generation>.t<index>`)** | Rejected: D8. They solve a problem an additive, human-confirmed write doesn't have. |
| **Copy Yes Chef's code** | Rejected: jon-platform ADR-0009. This is the second implementation, so it's the lift. |

## Consequences

- Staging takes a confirmation in the chat and one tap in the app. Neither crossing needs copying once read tools land.
- The whole path needs the Mac awake, with the tunnel running, for ChatGPT on any device. Without that, paste still works.
- iCloud Drive adds a delay between staging and the row: about 7 seconds in Yes Chef's foreground test.
- One tap can write a large set of synced rows. That's deliberate, and Dismiss has undo.
- `Processed/` lives in a synced folder, so it's pruned after 30 days (ADR-0007 Amendment 1-D3).
- New ops: one Platform tunnel and one login item for Galavant. The first TestFlight build with the entitlement may need
  iCloud Documents enabled by hand on both App IDs.
- ADR-0008 backups need the same entitlement, so adopting them later gets a little cheaper.

## Slices

Specified in [`chat-access`](../efforts/chat-access.md): **S1** the lift (`ChatAccessKit` inbox half, Yes Chef rewired);
**S2** candidates (entitlement, helper, tool, Evaluate rows, import); **S3** seeds; **S4** read tools (export half of the kit,
the Galavant export, `list_trips`, `get_trip`). S2 and S3 need `hand-off-purposes` landed first for the classifier and for
seed review's new seam.

## Open questions

- **OQ1 — large sets.** Is one tap right for 40 options, or should a very large set ask first? Decide from dogfooding.
- **OQ2 — plugin skills.** One iPhone test on Yes Chef answers this for every app (`jon-platform/docs/ios/mcp-access.md`).
- **OQ3 — the set's home device.** A set stays on the device that imported it. If Jon keeps wanting it on the other device,
  that's a question about ADR-0036 D1's device-local session, not about this door.
