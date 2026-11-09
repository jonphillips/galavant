# Chat Access setup

**Status:** Active · **Summary:** Install, connect, check, and refresh the Galavant chat helper.

Chat Access lets a ChatGPT chat read Galavant's trips and stage options into Evaluate ([ADR-0052](decisions/0052-chat-access-over-mcp.md)).
It has three parts, and all three must be in place before a chat can use it:

| Part | Where | What it is |
| --- | --- | --- |
| Helper | Mac | `~/.local/bin/galavant-mcp`, built from `GalavantMCP/` |
| Tunnel | Mac and OpenAI | The `galavant` `tunnel-client` profile on health port **8082**, run by a login agent |
| Export | iPhone or iPad | Chat Access turned on in the app, which writes the trip export to iCloud Drive |

The general tunnel mechanics are in `jon-platform/docs/ios/mcp-access.md`. This page holds the Galavant values, so
every command below can be pasted as is.

## Is it already set up?

```sh
ls ~/.local/bin/galavant-mcp                                  # helper installed
~/code/jon-platform/scripts/mcp-tunnel status galavant         # live, ready, agent: loaded (galavant)
ls -R ~/Library/Mobile\ Documents/iCloud~com~jonphillips~galavant/MCP/Exports   # one .json per device
```

A missing helper or `no health port recorded` from `status` means first-time setup was never done. An empty or missing
`MCP/Exports` means no device has turned on Chat Access.

## First-time setup

Do these in order. Step 5 is easy to miss, and the chat can't find any trip until it's done.

1. **Install the helper.** The script is in jon-platform, not this repo:

   ```sh
   ~/code/jon-platform/scripts/install-mcp-helper ~/code/galavant/galavant/GalavantMCP galavant-mcp
   ```

   It ends by printing `/Users/jon/.local/bin/galavant-mcp`. Compiler warnings from `GalavantLibrary` above that line
   are expected, and `swift-build: exit=0` means it worked.
2. **Create the tunnel.** At platform.openai.com → Settings → Organization → **Tunnels**, create one named `galavant`.
   Link it to both the personal Platform organization and the ChatGPT account, then copy its `tunnel_…` ID.
3. **Runtime key: usually skip.** One key serves every app's tunnel on a Mac. If Vinyl Fever or Yes Chef already
   runs a tunnel here, it's stored already. Check with
   `security find-generic-password -s openai-tunnel-runtime >/dev/null && echo stored`. Only if that prints nothing,
   follow `mcp-access.md` step 2 and run `~/code/jon-platform/scripts/mcp-tunnel store-key`.
4. **Create the profile and start it.** Galavant's health port is **8082**. Vinyl Fever has 8080 and Yes Chef 8081,
   so leaving `--health-port` off collides with Vinyl Fever and the agent won't start:

   ```sh
   ~/code/jon-platform/scripts/mcp-tunnel init galavant tunnel_XXXX ~/.local/bin/galavant-mcp --health-port 8082
   ~/code/jon-platform/scripts/mcp-tunnel install-agent galavant
   ~/code/jon-platform/scripts/mcp-tunnel status galavant
   ```

   `status` should end with `live`, `ready`, and `agent: loaded (galavant)`.
5. **Turn on Chat Access in the app.** On the iPhone and the iPad, go to Settings → Chat Access, turn on the toggle,
   and tap **Refresh**. Last export and Size appear under it. Within a minute or so the Mac has
   `MCP/Exports/<installation id>.json`, as in the check above. Until then, every chat that doesn't start from a hand-off
   brief fails with "No Galavant export yet".
6. **Add the plugin in ChatGPT.** Follow `mcp-access.md` step 6: add a custom MCP server named Galavant, choose
   Connection **Tunnel** and the `galavant` tunnel, with No authentication. It lists three tools: `list_trips`,
   `get_trip`, and `stage_trip_return`.
7. **Smoke test.** In a new chat with no brief, ask about a trip. It should call `list_trips` and then `get_trip`, and
   say how old the export is. The full checks are the chat-access entries in [device-passes.md](device-passes.md).

## After updating the checkout

Reinstall the helper (step 1), then restart the tunnel and refresh the plugin's tools:

```sh
~/code/jon-platform/scripts/mcp-tunnel uninstall-agent galavant
~/code/jon-platform/scripts/mcp-tunnel install-agent galavant
```

In ChatGPT, use **Refresh** on the plugin's detail page. In Galavant, Settings → Chat Access → Refresh updates the
export time and size.

## How a chat finds the trip

- **From a hand-off brief.** The brief carries a `GV-TRIP` line and a `GV-HANDOFF` token, so `stage_trip_return` works
  even without an export. The export only adds a check that the trip exists.
- **From a blank chat.** The chat has no trip ID until it calls `list_trips`, which reads the export. With no export,
  that call fails with "No Galavant export yet", and so does any staging that depends on it.

With Chat Access on, the app writes an export when you tap Refresh, and when it goes to the background, at most once
every 15 minutes. A blank chat sees trips only as of the latest export, and the read tools report its age. If a trip
is newer than the export, tap Refresh first.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| "No Galavant export yet" | No device has written an export. Do step 5, then check `MCP/Exports` on the Mac. If the Mac has no `MCP` folder at all, no device has ever turned Chat Access on. |
| "The Galavant export is still downloading from iCloud" | The export exists but the Mac hasn't downloaded it yet. Try again in a minute. |
| "The iCloud Drive container is unavailable" | The Mac has never synced Galavant's container. Check that iCloud Drive is on, and that `~/Library/Mobile Documents/iCloud~com~jonphillips~galavant` exists. |
| "That trip ID isn't in the latest Galavant export" | The chat guessed a trip ID, or the trip is newer than the export. Have it call `list_trips`, or tap Refresh in the app. |
| Refresh shows a red error | The message says what to retry. If it's an iCloud error, the build may be missing iCloud Documents on its App ID (`device-passes.md`, chat-access setup). |
| The export is in `MCP-Dev/`, not `MCP/` | A Debug build wrote it. The tunnel's helper reads production `MCP/` only, so use a TestFlight build, or run the helper with `--variant dev`. |
| `status`: `no health port recorded` | The profile was never created with `init`. Run step 4. |
| Tunnel or plugin problems | See the troubleshooting table in `mcp-access.md`. |

Moving to the always-on Mac: repeat steps 1, 3, and 4 there. Each app's helper reads only its own iCloud Drive
container, so nothing else moves (`jon-platform/docs/always-on-mac.md`).
