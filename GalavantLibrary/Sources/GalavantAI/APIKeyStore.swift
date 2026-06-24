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

  /// A non-secret preview of a stored key — first/last few characters plus length —
  /// so the settings UI can confirm a paste/entry actually took (the secret itself
  /// is never shown). Pure, so it's unit-tested without the Keychain.
  public static func masked(_ key: String) -> String {
    let visible = 4
    guard key.count > visible * 2 else {
      // Too short to reveal ends without exposing most of it — just the length.
      return "•••• · \(key.count) chars"
    }
    return "\(key.prefix(visible))…\(key.suffix(visible)) · \(key.count) chars"
  }

  /// The masked preview of the stored key for `provider`, or nil when none is set.
  public func maskedKey(_ provider: FrontierProvider) -> String? {
    read(provider).map(Self.masked)
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
    // `kSecAttrSynchronizableAny` is valid here (a query) — match a key whether it
    // was stored synchronizable or not.
    var query = matchQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data,
      let key = String(data: data, encoding: .utf8)
    else { return nil }
    return key
  }

  /// Store (or, with a nil key, clear) the credential. Replacing must be reliable —
  /// the whole point of the settings screen — so this deletes any existing item
  /// (synchronizable or not) and adds a fresh one with an **explicit** synchronizable
  /// Boolean (`kSecAttrSynchronizableAny` is a query-only value and makes `SecItemAdd`
  /// fail with `errSecParam` — the original clear/replace bug). On the off chance a
  /// stray item survives the delete, fall back to an in-place update.
  static func write(_ key: String?, account: String) {
    SecItemDelete(matchQuery(account: account) as CFDictionary)
    guard let key, let data = key.data(using: .utf8) else { return }
    var attributes = identityQuery(account: account)
    attributes[kSecAttrSynchronizable as String] = kCFBooleanTrue
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    attributes[kSecValueData as String] = data
    let status = SecItemAdd(attributes as CFDictionary, nil)
    if status == errSecDuplicateItem {
      SecItemUpdate(
        identityQuery(account: account) as CFDictionary,
        [kSecValueData as String: data] as CFDictionary)
    }
  }

  /// Match query for read/delete: spans synchronizable *and* non-synchronizable
  /// items so a re-save or clear catches a key stored either way (including legacy
  /// ones written before the synchronizable Boolean was set explicitly).
  private static func matchQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
    ]
  }

  /// The item's identity (no synchronizable predicate) — the base for `SecItemAdd`
  /// attributes and `SecItemUpdate` queries, where `…Any` is not permitted.
  private static func identityQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
