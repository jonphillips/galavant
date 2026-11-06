import ChatAccessKit
import Dependencies
import DependenciesTestSupport
import Foundation
import GalavantSchema
import Synchronization
import Testing
import UIKit

@testable import Galavant

@Suite(.serialized, .dependencies {
  try $0.bootstrapDatabase()
  $0.date = .constant(Date(timeIntervalSince1970: 1_000))
  $0.uuid = .incrementing
})
@MainActor
struct ChatExportModelTests {
  private struct State: Sendable {
    var folderCalls = 0
    var assertionBegins = 0
    var expiration: (@MainActor @Sendable () -> Void)?
  }

  @Test func disabledAndThrottledBackgroundCallsDoNoFolderWork() async throws {
    let oldEnabled = UserDefaults.standard.object(forKey: ChatInboxModel.enabledKey)
    defer { UserDefaults.standard.set(oldEnabled, forKey: ChatInboxModel.enabledKey) }
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let state = Mutex(State())
    let folder = ChatAccessFolder(containerURL: FileManager.default.temporaryDirectory, isDevelopment: true)
    let client = ChatAccessContainerClient(resolveFolder: {
      state.withLock { $0.folderCalls += 1 }
      return folder
    }, resolveAndCreateInbox: { folder })
    let bg = ChatExportBackgroundTaskClient(begin: { _, _ in state.withLock { $0.assertionBegins += 1 }; return 1 }, end: { _ in })
    UserDefaults.standard.set(false, forKey: ChatInboxModel.enabledKey)
    withDependencies({ $0.chatAccessContainer = client }) {
      let model = ChatExportModel(defaults: defaults, backgroundTaskClient: bg)
      NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
      #expect(state.withLock { $0.folderCalls == 0 && $0.assertionBegins == 0 })
      _ = model
    }

    let writer = ChatAccessExportWriter(defaults: defaults, makeUUID: { UUID() })
    _ = try await writer.write(Data("previous".utf8), to: folder, generatedAt: Date(timeIntervalSince1970: 1_000), force: true)
    UserDefaults.standard.set(true, forKey: ChatInboxModel.enabledKey)
    withDependencies({
      $0.chatAccessContainer = client
      $0.date = .constant(Date(timeIntervalSince1970: 1_001))
    }) {
      let model = ChatExportModel(defaults: defaults, backgroundTaskClient: bg)
      NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
      #expect(state.withLock { $0.folderCalls == 0 && $0.assertionBegins == 0 })
      _ = model
    }
  }

  @Test func refreshForcesAWriteWhileThrottledAndAssertionExpiryCancels() async throws {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let folder = ChatAccessFolder(containerURL: home, isDevelopment: true)
    let writer = ChatAccessExportWriter(defaults: defaults, makeUUID: { UUID() })
    _ = try await writer.write(Data("previous".utf8), to: folder, generatedAt: Date(timeIntervalSince1970: 1_000), force: true)
    let client = ChatAccessContainerClient(resolveFolder: { folder }, resolveAndCreateInbox: { folder })
    let bg = ChatExportBackgroundTaskClient(begin: { _, _ in 7 }, end: { _ in })
    await withDependencies {
      $0.chatAccessContainer = client
      $0.chatExportDevice = ChatExportDeviceClient(idiom: { .phone })
      $0.date = .constant(Date(timeIntervalSince1970: 1_001))
    } operation: {
      let model = ChatExportModel(defaults: defaults, backgroundTaskClient: bg)
      model.refresh()
      while model.isRefreshing { await Task.yield() }
      #expect(model.errorMessage == nil)
      #expect(model.lastExport?.date == Date(timeIntervalSince1970: 1_001))
    }

    let expiringDefaults = UserDefaults(suiteName: UUID().uuidString)!
    let state = Mutex(State())
    let expiringClient = ChatAccessContainerClient(resolveFolder: {
      return folder
    }, resolveAndCreateInbox: { folder })
    let expiryClient = ChatExportBackgroundTaskClient(begin: { _, expire in
      state.withLock { $0.assertionBegins += 1; $0.expiration = expire }
      return 8
    }, end: { _ in })
    UserDefaults.standard.set(true, forKey: ChatInboxModel.enabledKey)
    await withDependencies {
      $0.chatAccessContainer = expiringClient
      $0.date = .constant(Date(timeIntervalSince1970: 2_000))
    } operation: {
      let model = ChatExportModel(defaults: expiringDefaults, backgroundTaskClient: expiryClient)
      NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
      state.withLock { $0.expiration }?()
      for _ in 0..<3 { await Task.yield() }
      #expect(model.lastExport == nil)
      #expect(state.withLock { $0.assertionBegins == 1 })
    }
  }
}
