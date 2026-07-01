import GalavantSchema
import SwiftUI

/// The adaptive navigation shell: a tab bar on iPhone, a sidebar + detail split
/// on iPad and Mac. Each section gets its own navigation stack.
struct AppContainer: View {
  @State private var router = AppRouter()
  @State private var browserModel = BrowserScreenModel()
  @Environment(\.prefersTabNavigation) private var prefersTabNavigation
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    @Bindable var router = router
    Group {
      if prefersTabNavigation {
        TabView(selection: $router.selection) {
          ForEach(AppScreen.allCases) { screen in
            NavigationStack {
              screen.destination
            }
            .tag(screen as AppScreen?)
            .tabItem { screen.label }
          }
        }
      } else {
        NavigationSplitView {
          List(AppScreen.allCases, selection: $router.selection) { screen in
            screen.label
          }
          .navigationTitle("Galavant")
        } detail: {
          // One stable NavigationStack; the root swaps by selection. Per-trip
          // push is state-driven via `router.openTrip` (ADR-0013 follow-up) — a
          // bound *path* here traps the split-view column on teardown.
          NavigationStack {
            if let selection = router.selection {
              selection.destination
            } else {
              ContentUnavailableView(
                "Pick a section",
                systemImage: Icon.sidebar.systemName
              )
            }
          }
        }
      }
    }
    .environment(router)
    .environment(browserModel)
    .onChange(of: scenePhase) { _, phase in
      // Consumer-side drain: the pending-changes table drains only inside `start()`,
      // and a running engine never re-reads it. The launch → background → share →
      // foreground path (app resumed, not relaunched) leaves the extension's pending
      // rows undrained. On activation, cycle stop()+start() when the count is non-zero
      // so `start()` re-drains — gated on the count so it fires only right after a share.
      guard phase == .active else { return }
      Task { _ = await GalavantCloudSync.redrainPendingRecordZoneChangesIfManuallyEnabled() }
    }
  }
}
