import Dependencies
import Foundation
import Security
import Synchronization

/// Device-local storage for frontier API keys (ADR-0014 §1): the one credential
/// that is **not** travel-party-shared — a personal access credential like the
/// iCloud login, living in the Keychain (and synced across the user's own devices
/// by iCloud Keychain), never in a SQLiteData/CloudKit table. Injectable so the
/// settings model and `TieredModelClient.live` are testable without touching the
/// real Keychain.
public struct APIKeyStore: Sendable {
  var read: @Sendable (FrontierProvider) -> String?
  var write: @Sendable (FrontierProvider, String?) -> Void

  public init(
    read: @escaping @Sendable (FrontierProvider) -> String?,
    write: @escaping @Sendable (FrontierProvider, String?) -> Void
  ) {
    self.read = read
    self.write = write
  }

  /// The stored key for a provider, or nil when none is set (frontier disabled).
  public func key(_ provider: FrontierProvider) -> String? { read(provider) }

  /// Store a key, or clear it by passing `nil` (or an empty string).
  public func setKey(_ key: String?, for provider: FrontierProvider) {
    let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
    write(provider, (trimmed?.isEmpty ?? true) ? nil : trimmed)
  }
}

extension APIKeyStore: DependencyKey {
  /// iCloud-Keychain-synced generic-password items, one per provider. The
  /// `kSecAttrSynchronizable` flag is what carries the key across the user's own
  /// devices — the "iCloud account is the identity" model ADR-0001 already relies
  /// on, applied to this one device-local credential.
  public static let liveValue = APIKeyStore(
    read: { provider in Keychain.read(account: provider.rawValue) },
    write: { provider, key in Keychain.write(key, account: provider.rawValue) }
  )

  /// In-memory store for tests/previews — no Keychain access, deterministic.
  public static var testValue: APIKeyStore { inMemory() }
  public static var previewValue: APIKeyStore { inMemory() }

  static func inMemory() -> APIKeyStore {
    let storage = Mutex<[FrontierProvider: String]>([:])
    return APIKeyStore(
      read: { provider in storage.withLock { $0[provider] } },
      write: { provider, key in storage.withLock { $0[provider] = key } }
    )
  }
}

extension DependencyValues {
  public var apiKeyStore: APIKeyStore {
    get { self[APIKeyStore.self] }
    set { self[APIKeyStore.self] = newValue }
  }
}

/// Minimal Keychain wrapper for synchronizable generic-password items. Kept
/// private to the live store — callers see `APIKeyStore`.
private enum Keychain {
  static let service = "com.jonphillips.galavant.apikeys"

  static func read(account: String) -> String? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data,
      let key = String(data: data, encoding: .utf8)
    else { return nil }
    return key
  }

  static func write(_ key: String?, account: String) {
    SecItemDelete(baseQuery(account: account) as CFDictionary)
    guard let key, let data = key.data(using: .utf8) else { return }
    var query = baseQuery(account: account)
    query[kSecValueData as String] = data
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    SecItemAdd(query as CFDictionary, nil)
  }

  private static func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
    ]
  }
}
