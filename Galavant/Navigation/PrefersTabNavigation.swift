import SwiftUI

/// True on iPhone (use tabs); false on iPad/Mac (use a sidebar + detail split).
/// Ported from V2 — bridges the UIKit idiom trait into the SwiftUI environment.
struct PrefersTabNavigationEnvironmentKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var prefersTabNavigation: Bool {
    get { self[PrefersTabNavigationEnvironmentKey.self] }
    set { self[PrefersTabNavigationEnvironmentKey.self] = newValue }
  }
}

#if os(iOS)
  extension PrefersTabNavigationEnvironmentKey: UITraitBridgedEnvironmentKey {
    static func read(from traitCollection: UITraitCollection) -> Bool {
      traitCollection.userInterfaceIdiom == .phone
    }

    static func write(to mutableTraits: inout UIMutableTraits, value: Bool) {
      // Read-only; derived from the idiom.
    }
  }
#endif
