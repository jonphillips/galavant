import SwiftUI

extension Binding {
  /// A `Binding<Bool>` that reads `true` while the optional holds a value and, when
  /// set to `false`, clears it back to `nil`. The reusable form of the
  /// `Binding(get: { x != nil }, set: { if !$0 { x = nil } })` shape — for driving
  /// an `isPresented:` API off optional payload state (e.g. a rename alert keyed on
  /// the item being renamed). SwiftUINavigation's case-path bindings cover the
  /// enum-Destination case; this covers a plain optional payload.
  ///
  /// `Wrapped: Sendable` keeps the underlying `Binding` `Sendable`, so the `get`/`set`
  /// closures don't warn on capturing it (matching how SwiftUINavigation constrains
  /// its own derived-binding helpers).
  func isPresent<Wrapped: Sendable>() -> Binding<Bool> where Value == Wrapped? {
    Binding<Bool>(
      get: { wrappedValue != nil },
      set: { isPresented in
        if !isPresented { wrappedValue = nil }
      }
    )
  }
}
