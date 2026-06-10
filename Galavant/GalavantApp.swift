import Dependencies
import GalavantSchema
import SwiftUI

@main
struct GalavantApp: App {
  init() {
    try! prepareDependencies {
      try $0.bootstrapDatabase()
    }
  }

  var body: some Scene {
    WindowGroup {
      NavigationStack {
        IdeasListView()
      }
    }
  }
}
