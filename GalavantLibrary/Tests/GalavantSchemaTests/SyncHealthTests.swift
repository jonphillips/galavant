import GalavantSchema
import Testing

@Suite struct SyncHealthTests {
  /// A healthy, live device with nothing pending: the only combination that reads
  /// "Up to date".
  private func healthy(
    pending: Int = 0,
    lastError: String? = nil,
    running: Bool = true
  ) -> SyncHealth {
    SyncHealth(
      isManuallyEnabled: true,
      account: .available,
      isEngineRunning: running,
      pendingChangeCount: pending,
      lastError: lastError
    )
  }

  @Test("Gate off is disabled regardless of every other signal")
  func gateOffWins() {
    // Even a fully-live, mid-sync, erroring engine reads disabled when the gate is off.
    let health = SyncHealth(
      isManuallyEnabled: false,
      account: .available,
      isEngineRunning: true,
      pendingChangeCount: 5,
      lastError: "boom"
    )
    #expect(health.displayStatus == .disabled)
  }

  @Test(
    "Every unavailable account status maps to local-only with its own reason",
    arguments: [
      (SyncAccountStatus.noAccount, "no iCloud account"),
      (.restricted, "iCloud is restricted"),
      (.couldNotDetermine, "iCloud status unavailable"),
      (.temporarilyUnavailable, "iCloud temporarily unavailable"),
      (.unknown, "iCloud unavailable"),
    ]
  )
  func unavailableAccountIsLocalOnly(account: SyncAccountStatus, reason: String) {
    let health = SyncHealth(
      isManuallyEnabled: true,
      account: account,
      isEngineRunning: true,
      pendingChangeCount: 0
    )
    #expect(health.displayStatus == .localOnly(reason: reason))
  }

  @Test("An unavailable account outranks pending changes and a running engine")
  func unavailableAccountOutranksPending() {
    let health = SyncHealth(
      isManuallyEnabled: true,
      account: .noAccount,
      isEngineRunning: true,
      pendingChangeCount: 9
    )
    #expect(health.displayStatus == .localOnly(reason: "no iCloud account"))
  }

  @Test("A start error surfaces as .error once the account is available")
  func lastErrorSurfaces() {
    #expect(healthy(lastError: "CKError 9").displayStatus == .error("CKError 9"))
  }

  @Test("A pending error outranks pending changes")
  func lastErrorOutranksPending() {
    #expect(healthy(pending: 4, lastError: "boom").displayStatus == .error("boom"))
  }

  @Test("Enabled + available but not yet running reads local-only")
  func notRunningIsLocalOnly() {
    #expect(
      healthy(running: false).displayStatus == .localOnly(reason: "sync hasn’t started yet")
    )
  }

  @Test("Pending changes on a live engine read as syncing with the count")
  func pendingIsSyncing() {
    #expect(healthy(pending: 3).displayStatus == .syncing(pending: 3))
    #expect(healthy(pending: 1).displayStatus == .syncing(pending: 1))
  }

  @Test("Enabled, available, running, drained, no error is the only up-to-date state")
  func upToDate() {
    #expect(healthy().displayStatus == .upToDate)
  }

  @Test(
    "Row summaries read as the brief specifies",
    arguments: [
      (SyncDisplayStatus.disabled, "Sync is off"),
      (.localOnly(reason: "no iCloud account"), "On this device only — no iCloud account"),
      (.syncing(pending: 2), "Syncing…"),
      (.upToDate, "Up to date"),
      (.error("x"), "Sync error"),
    ]
  )
  func summaries(status: SyncDisplayStatus, expected: String) {
    #expect(status.summary == expected)
  }

  @Test("available is the only account status that reports itself available")
  func onlyAvailableIsAvailable() {
    for account in SyncAccountStatus.allCases {
      #expect(account.isAvailable == (account == .available))
    }
  }
}
