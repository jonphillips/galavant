import CustomDump
import Dependencies
@testable import GalavantSchema
import GRDB
import Synchronization
import Testing

struct SyncSuspensionTests {
  @Test func lifecyclePlans() {
    var plan = SyncSuspensionPlan()
    expectNoDifference(plan.enterBackground(), [.beginTask])
    expectNoDifference(plan.enterBackground(), [])
    expectNoDifference(plan.expire(quiet: true), [.stop, .suspend, .endTask])
    expectNoDifference(plan.expire(quiet: true), [])
    expectNoDifference(plan.enterForeground(), [.endTask, .resume, .start])
    expectNoDifference(plan.enterForeground(), [])

    expectNoDifference(plan.enterBackground(), [.beginTask])
    expectNoDifference(plan.expire(quiet: false), [.endTask])
    expectNoDifference(plan.enterForeground(), [.endTask])
    expectNoDifference(plan.enterBackground(), [.beginTask])
    expectNoDifference(plan.enterForeground(), [.endTask])

    expectNoDifference(plan.enterBackground(), [.beginTask])
    expectNoDifference(plan.expire(quiet: false), [.endTask])
    let denied = plan.allowStart()
    #expect(!denied)
    expectNoDifference(plan.enterForeground(), [.endTask, .start])
    let allowed = plan.allowStart()
    #expect(allowed)

    plan.bootstrapExpired()
    expectNoDifference(plan.enterBackground(), [])
    let launchAllowed = plan.allowStart()
    #expect(!launchAllowed)
    expectNoDifference(plan.enterForeground(), [.endTask, .resume, .start])
  }

  @Test func deniedStartRestartsOnForeground() async throws {
    let gate = SyncStartGate()
    let calls = Mutex(0)
    _ = gate.enterBackground()
    _ = gate.expire(isSynchronizing: { false }, perform: { _ in })
    await gate.run {
      try? await gate.start { calls.withLock { $0 += 1 } }
    }
    #expect(calls.withLock { $0 } == 0)
    var effects: [SyncSuspensionPlan.Effect] = []
    gate.enterForeground { effects.append($0) }
    expectNoDifference(effects, [.endTask, .resume, .start])
    await gate.run {
      try? await gate.start { calls.withLock { $0 += 1 } }
    }
    #expect(calls.withLock { $0 } == 1)
  }

  @Test func redrainWaitsForStartAndDoesNotEnqueueItsOwnStart() async {
    let gate = SyncStartGate()
    let (events, eventSink) = AsyncStream<String>.makeStream()
    let (release, releaseSink) = AsyncStream<Void>.makeStream()
    var iterator = events.makeAsyncIterator()
    let first = Task {
      await gate.run {
        try? await gate.start {
          eventSink.yield("started")
          for await _ in release { break }
          eventSink.yield("finished")
        }
      }
    }
    #expect(await iterator.next() == "started")
    let quiet = gate.expire(isSynchronizing: { false }, perform: { _ in })
    #expect(!quiet)
    let second = Task {
      await gate.run {
        eventSink.yield("stop")
        try? await gate.start { eventSink.yield("restart") }
      }
    }
    while gate.operationCount < 2 { await Task.yield() }
    releaseSink.yield(())
    #expect(await iterator.next() == "finished")
    #expect(await iterator.next() == "stop")
    await first.value
    await second.value
    var effects: [SyncSuspensionPlan.Effect] = []
    gate.enterForeground { effects.append($0) }
    expectNoDifference(effects, [.endTask, .start])
    eventSink.finish()
    releaseSink.finish()
  }

  @Test func redrainCanStartDirectlyWithinItsSerialOperation() async {
    let gate = SyncStartGate()
    let calls = Mutex([String]())
    await gate.run {
      calls.withLock { $0.append("stop") }
      try? await gate.start { calls.withLock { $0.append("start") } }
    }
    expectNoDifference(calls.withLock { $0 }, ["stop", "start"])
  }

  @Test func interruptedSyncSetupDegradesButMigrationFailureEscapes() throws {
    for code: ResultCode in [.SQLITE_INTERRUPT, .SQLITE_ABORT] {
      var dependencies = DependencyValues()
      withKnownIssue {
        try dependencies.bootstrapDatabase(
          syncMode: .configured(startImmediately: false), migrate: { _ in },
          makeSyncEngine: { _, _ in throw DatabaseError(resultCode: code) }
        )
      }
      #expect(!dependencies.syncEngineAvailable)
      let result = try dependencies.defaultDatabase.read { db in
        try Int.fetchOne(db, sql: "SELECT 1")
      }
      #expect(result == 1)
    }
    struct MigrationError: Error {}
    var dependencies = DependencyValues()
    #expect(throws: MigrationError.self) {
      try dependencies.bootstrapDatabase(
        syncMode: .configured(startImmediately: false),
        migrate: { _ in throw MigrationError() },
        makeSyncEngine: { _, _ in fatalError("Migration failure must prevent setup") }
      )
    }
  }
}
