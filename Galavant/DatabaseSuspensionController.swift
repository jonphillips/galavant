import Dependencies
import GalavantSchema
import OSLog
import SQLiteData
import UIKit

/// Owns the process-wide background assertion, independent of individual scenes.
@MainActor
final class DatabaseSuspensionController: NSObject {
  @Dependency(\.syncStartGate) private var gate
  @Dependency(\.defaultSyncEngine) private var engine
  @Dependency(\.syncEngineAvailable) private var engineAvailable
  private let application: UIApplication
  private let logger = Logger(subsystem: "com.jonphillips.galavant", category: "Suspension")
  private var task: UIBackgroundTaskIdentifier = .invalid

  init(application: UIApplication) {
    self.application = application
    super.init()
    NotificationCenter.default.addObserver(
      self, selector: #selector(enterBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil
    )
    NotificationCenter.default.addObserver(
      self, selector: #selector(enterForeground),
      name: UIApplication.willEnterForegroundNotification, object: nil
    )
    if application.applicationState == .background {
      enterBackground()
    } else {
      // The process may have returned to foreground before observers were installed.
      enterForeground()
    }
  }

  @objc private func enterBackground() {
    guard gate.enterBackground().contains(.beginTask) else { return }
    task = application.beginBackgroundTask(withName: "Finish database sync") { [weak self] in
      self?.expire()
    }
    if task == .invalid { expire() }
  }

  private func expire() {
    let quiet = gate.expire(isSynchronizing: { engineAvailable && engine.isSynchronizing }) { effect in
      switch effect {
      case .stop: if engineAvailable { engine.stop() }
      case .suspend: NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
      case .endTask: endTask()
      default: break
      }
    }
    let outcome = quiet ? "suspended" : "busy"
    logger.notice("Background time expired: \(outcome, privacy: .public)")
  }

  @objc private func enterForeground() {
    var shouldStart = false
    gate.enterForeground { effect in
      switch effect {
      case .endTask: endTask()
      case .resume: NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
      case .start: shouldStart = true
      default: break
      }
    }
    if shouldStart { Task { _ = await GalavantCloudSync.startIfManuallyEnabled() } }
  }

  private func endTask() {
    guard task != .invalid else { return }
    application.endBackgroundTask(task)
    task = .invalid
  }
}
