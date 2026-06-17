import Foundation

/// Cross-process "the shared database changed" signal.
///
/// SQLiteData/GRDB observation (`@FetchAll`) only fires for writes made on its own
/// connection, so a commit from the share extension's *separate process* is
/// invisible to an already-running app until it re-reads. The writer posts a Darwin
/// notification after committing; the app bridges it to an `AsyncStream` and
/// reloads its queries. (Foreground `scenePhase` reloads cover the common
/// background-while-sharing path on iOS; this covers an app that's live at write
/// time — e.g. on the Mac, where both can be visible at once.)
public enum DatabaseChange {
  // A plain `String` (Sendable) so the Darwin teardown closure can reference it;
  // bridged to `CFString` at each call site.
  private static let darwinName = "com.jonphillips.galavant.databaseDidChange"

  /// Post from the writing process (the share extension) right after a successful
  /// commit to the shared database.
  public static func post() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(rawValue: darwinName as CFString),
      nil, nil, true
    )
  }

  /// Emits whenever another process posts a change. Iterate it from the app; the
  /// Darwin observer is registered on first iteration and torn down when the
  /// consuming task is cancelled.
  public static var notifications: AsyncStream<Void> {
    AsyncStream { continuation in
      // The Darwin callback is a context-free C function pointer, so smuggle the
      // continuation through the observer pointer.
      let observer = Unmanaged.passRetained(Box(continuation)).toOpaque()
      CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), observer,
        { _, observer, _, _, _ in
          guard let observer else { return }
          Unmanaged<Box>.fromOpaque(observer).takeUnretainedValue().continuation.yield()
        },
        darwinName as CFString, nil, .deliverImmediately
      )
      let handle = ObserverHandle(observer)
      continuation.onTermination = { _ in
        CFNotificationCenterRemoveObserver(
          CFNotificationCenterGetDarwinNotifyCenter(), handle.pointer,
          CFNotificationName(rawValue: darwinName as CFString), nil
        )
        Unmanaged<Box>.fromOpaque(handle.pointer).release()
      }
    }
  }

  private final class Box {
    let continuation: AsyncStream<Void>.Continuation
    init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
  }

  /// The retained observer pointer is balanced by exactly one `release()` in
  /// `onTermination`; safe to ferry across the Sendable boundary.
  private struct ObserverHandle: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
    init(_ pointer: UnsafeMutableRawPointer) { self.pointer = pointer }
  }
}
