# Effort — Adopt ChatAccessKit's export refresh

**Status:** Blocked · **Summary:** Replace `ChatExportModel`'s background task, gating, and cancellation with the shared
export refresh in `ChatAccessKit`, keeping Galavant's export builder. Blocked until Yes Chef's
`chat-access-export-refresh` Part 1 merges the package. No schema, sync, export-format, or behavior change.

**Implements:** jon-platform [ADR-0011](../../../jon-platform/docs/adr/0011-chat-access-export-refresh.md) D4 step 3. The
kit was lifted from this app's `ChatExportModel`, so adopting it should change nothing a person can see. The architect
flips this brief to Ready once the package PR merges.

## The work

1. **`Galavant/ChatAccess/ChatExportModel.swift`:** keep the type, its Settings surface, and `ChatExportRows`. Hand the
   lifecycle to the kit. The build closure fetches `ChatExportRows`, then runs `GalavantChatExportBuilder.build` and
   encodes, as today. `isEnabled` reads `ChatInboxModel.enabledKey`.
2. **Delete** `ChatExportDeviceClient`, `ChatExportBackgroundTaskClient`, and `ExportAssertion`, along with their
   dependency key, in favor of the kit's clients.
3. **The `didEnterBackgroundNotification` observer** stays in the app (ADR-0011 keeps the hookup app-owned) and calls
   the kit's background entry point. Refresh calls `refresh()`.
4. **Messages:** word the kit's outcome with today's strings ("The export was throttled. Try Refresh again." and the
   others).
5. **Tests:** `GalavantTests/ChatExportModelTests.swift`'s lifecycle cases moved into the kit. Keep one Galavant test that
   a refresh writes an export decoding as Galavant's format, through the injected folder.

**Verification:** `scripts/check-drift.sh`, per `docs/verification.md`.

**Done when:** `ChatExportModel` has no background-task or assertion code of its own, the tests pass, and closeout runs
(ADR-0005 D16). No device gate: Yes Chef's gate covers the shared lifecycle, and nothing here changes behavior.
