import CloudKit
import Dependencies
import GalavantSchema
import OSLog
import SQLiteData
import SwiftUI
import Synchronization

@main
struct GalavantApp: App {
  @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

  init() {
    let gate = SyncStartGate()
    let activityReady = DispatchSemaphore(value: 0)
    let activityFinished = DispatchSemaphore(value: 0)
    let bootstrapFinished = Mutex(false)
    // The activity runs off the main thread, so its expiration callback can interrupt
    // a synchronous bootstrap even while App.init is holding the main thread.
    ProcessInfo.processInfo.performExpiringActivity(withReason: "Bootstrap shared database") { expired in
      if expired {
        bootstrapFinished.withLock { finished in
          guard !finished else { return }
          gate.bootstrapExpired {
            NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
          }
        }
        activityReady.signal()
      } else {
        activityReady.signal()
        activityFinished.wait()
      }
    }
    activityReady.wait()
    do {
      try prepareDependencies {
        $0.syncStartGate = gate
        try $0.bootstrapDatabase()
      }
    } catch {
      if gate.shouldExitBootstrap(for: error) {
        Logger(subsystem: "com.jonphillips.galavant", category: "Bootstrap")
          .notice("Bootstrap expired and database setup was interrupted; exiting for a clean launch")
        exit(0)
      }
      fatalError("Database bootstrap failed: \(error)")
    }
    bootstrapFinished.withLock { $0 = true }
    activityFinished.signal()
    // Mirror the dev launch-arg into persistent defaults so the gate survives an icon
    // relaunch or a hand-back from the share extension (the "enablement trap").
    GalavantCloudSync.persistManualEnablementFromLaunchEnvironment()
    // The engine was constructed stopped; start it only if the gate is on and iCloud
    // is available. Cold-launch `start()` also drains any pending changes a share
    // extension left behind while the app wasn't running.
    Task { _ = await GalavantCloudSync.startIfManuallyEnabled() }
    #if DEBUG
      DemoFixtures.seedIfRequested()
    #endif
  }

  var body: some Scene {
    WindowGroup {
      AppContainer()
    }
  }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
  private var suspensionController: DatabaseSuspensionController?

  func application(
    _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    suspensionController = DatabaseSuspensionController(application: application)
    return true
  }

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(
      name: "Default Configuration",
      sessionRole: connectingSceneSession.role
    )
    configuration.delegateClass = SceneDelegate.self
    return configuration
  }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  @Dependency(\.defaultSyncEngine) var syncEngine
  @Dependency(\.syncEngineAvailable) var syncEngineAvailable

  func windowScene(
    _ windowScene: UIWindowScene,
    userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
  ) {
    guard syncEngineAvailable else { return }
    Task {
      try await syncEngine.acceptShare(metadata: cloudKitShareMetadata)
    }
  }

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard syncEngineAvailable, let cloudKitShareMetadata = connectionOptions.cloudKitShareMetadata
    else { return }
    Task {
      try await syncEngine.acceptShare(metadata: cloudKitShareMetadata)
    }
  }
}
