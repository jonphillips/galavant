import ChatAccessKit
import Dependencies
import Foundation
import GalavantSchema
import Observation
import SQLiteData
import UIKit

struct ChatExportDeviceClient: Sendable {
  var idiom: @MainActor @Sendable () -> UIUserInterfaceIdiom
  static let live = Self(idiom: { UIDevice.current.userInterfaceIdiom })
}

struct ChatExportBackgroundTaskClient: Sendable {
  var begin: @MainActor @Sendable (_ name: String, _ onExpire: @escaping @MainActor @Sendable () -> Void) -> Int
  var end: @MainActor @Sendable (Int) -> Void

  static func live(application: UIApplication) -> Self {
    Self(begin: { name, onExpire in
      let identifier = application.beginBackgroundTask(withName: name) { Task { @MainActor in onExpire() } }
      return identifier.rawValue
    }, end: { application.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: $0)) })
  }
}

@MainActor
private final class ExportAssertion {
  private var identifier: Int = UIBackgroundTaskIdentifier.invalid.rawValue
  private let client: ChatExportBackgroundTaskClient

  init(client: ChatExportBackgroundTaskClient) { self.client = client }

  func begin(onExpire: @escaping @MainActor @Sendable () -> Void) -> Bool {
    identifier = client.begin("GalavantChatAccessExport", onExpire)
    return identifier != UIBackgroundTaskIdentifier.invalid.rawValue
  }

  func end() {
    guard identifier != UIBackgroundTaskIdentifier.invalid.rawValue else { return }
    let current = identifier
    identifier = UIBackgroundTaskIdentifier.invalid.rawValue
    client.end(current)
  }
}

private struct ChatExportRows: Sendable {
  var trips: [Trip]
  var entries: [TripIdea]
  var ideas: [Idea]
  var stays: [TripStay]
  var dayRegions: [TripDayRegion]
  var regions: [MapRegion]
  var constraints: [CalendarTripConstraint]
  var alternativeGroups: [TripAlternativeGroup]
  var profiles: [TravelProfile]
  var planners: [Planner]
}

@MainActor
@Observable
final class ChatExportModel: NSObject {
  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @Dependency(\.date.now) private var now
  @ObservationIgnored @Dependency(\.chatAccessContainer) private var folderClient
  @ObservationIgnored @Dependency(\.chatExportDevice) private var deviceClient
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let backgroundTaskClient: ChatExportBackgroundTaskClient
  @ObservationIgnored private let writer: ChatAccessExportWriter
  @ObservationIgnored private var task: Task<Void, Never>?
  private(set) var isRefreshing = false
  private(set) var errorMessage: String?

  init(application: UIApplication = .shared, defaults: UserDefaults = .standard,
       backgroundTaskClient: ChatExportBackgroundTaskClient? = nil) {
    @Dependency(\.uuid) var uuid
    self.defaults = defaults
    self.backgroundTaskClient = backgroundTaskClient ?? .live(application: application)
    writer = ChatAccessExportWriter(defaults: defaults, makeUUID: { uuid() })
    super.init()
    NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
  }

  isolated deinit { NotificationCenter.default.removeObserver(self) }

  var lastExport: ChatAccessExportWriter.LastExport? { writer.lastExport }

  @objc private func didEnterBackground() {
    guard defaults.bool(forKey: ChatInboxModel.enabledKey), writer.isDue(at: now) else { return }
    start(force: false)
  }

  func refresh() { start(force: true) }

  private func start(force: Bool) {
    guard !isRefreshing else { return }
    if !force {
      guard defaults.bool(forKey: ChatInboxModel.enabledKey), writer.isDue(at: now) else { return }
    }
    isRefreshing = true
    errorMessage = nil
    let assertion = ExportAssertion(client: backgroundTaskClient)
    let hasAssertion = assertion.begin { [weak self, weak assertion] in
      self?.task?.cancel()
      self?.task = nil
      self?.isRefreshing = false
      assertion?.end()
    }
    guard hasAssertion else {
      isRefreshing = false
      errorMessage = "Galavant couldn't start a background task for the export. Try Refresh again."
      return
    }
    task = Task { [weak self] in
      guard let self else { assertion.end(); return }
      defer { assertion.end(); isRefreshing = false; task = nil }
      do {
        try Task.checkCancellation()
        let folder = try await folderClient.resolveFolder()
        try Task.checkCancellation()
        let rows = try await database.read { db in
          ChatExportRows(
            trips: try Trip.all.fetchAll(db), entries: try TripIdea.all.fetchAll(db), ideas: try Idea.all.fetchAll(db),
            stays: try TripStay.all.fetchAll(db), dayRegions: try TripDayRegion.all.fetchAll(db), regions: try MapRegion.all.fetchAll(db),
            constraints: try CalendarTripConstraint.all.fetchAll(db), alternativeGroups: try TripAlternativeGroup.all.fetchAll(db),
            profiles: try TravelProfile.all.fetchAll(db), planners: try Planner.all.fetchAll(db))
        }
        try Task.checkCancellation()
        let timestamp = now
        let idiom = deviceClient.idiom()
        let device = idiom == .pad ? "iPad" : "iPhone"
        let calendar = Calendar.current
        let buildTask = Task.detached(priority: .utility) {
          let export = try GalavantChatExportBuilder.build(
            trips: rows.trips, entries: rows.entries, ideas: rows.ideas, stays: rows.stays,
            dayRegions: rows.dayRegions, regions: rows.regions, constraints: rows.constraints,
            alternativeGroups: rows.alternativeGroups, profiles: rows.profiles, planners: rows.planners,
            generatedAt: timestamp, device: device, calendar: calendar,
            checkCancellation: { try Task.checkCancellation() })
          try Task.checkCancellation()
          return try JSONEncoder().encode(export)
        }
        let data = try await withTaskCancellationHandler {
          try await buildTask.value
        } onCancel: {
          buildTask.cancel()
        }
        try Task.checkCancellation()
        let result = try await writer.write(data, to: folder, generatedAt: timestamp, force: force)
        if case .throttled = result { errorMessage = "The export was throttled. Try Refresh again." }
        if case .alreadyWriting = result { errorMessage = "An export is already being written. Try Refresh again." }
      } catch is CancellationError {
        // Assertion expiry cancels this work; the next background entry retries.
      } catch { errorMessage = error.localizedDescription }
    }
  }
}

private enum ChatExportDeviceKey: DependencyKey {
  static let liveValue = ChatExportDeviceClient.live
  static let testValue = ChatExportDeviceClient(idiom: { .phone })
}

extension DependencyValues {
  var chatExportDevice: ChatExportDeviceClient {
    get { self[ChatExportDeviceKey.self] }
    set { self[ChatExportDeviceKey.self] = newValue }
  }
}
