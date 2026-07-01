import CloudKit
import Dependencies
import GalavantSchema
import SQLiteData
import SwiftUI

@main
struct GalavantApp: App {
  @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

  init() {
    try! prepareDependencies {
      try $0.bootstrapDatabase()
    }
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

  func windowScene(
    _ windowScene: UIWindowScene,
    userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
  ) {
    Task {
      try await syncEngine.acceptShare(metadata: cloudKitShareMetadata)
    }
  }

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let cloudKitShareMetadata = connectionOptions.cloudKitShareMetadata
    else { return }
    Task {
      try await syncEngine.acceptShare(metadata: cloudKitShareMetadata)
    }
  }
}
