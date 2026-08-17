import Foundation

/// URL adjustments that keep web capture compatible with the platform's transport
/// security rules without weakening those rules. The helpers are pure so callers
/// can apply them at each network boundary and test the policy without a network.
public enum URLHygiene {
  /// Upgrade an `http://` URL to `https://` before we fetch it. iOS App Transport
  /// Security blocks cleartext `http` loads, so an idea whose only stored URL is
  /// `http://…` never gets fetched — even when the server would 301 straight to
  /// `https://`, because the initial cleartext request is blocked on-device before
  /// the redirect can happen. Fetching `https://` directly sidesteps ATS and
  /// matches browser HTTPS-first behavior. Non-HTTP URLs pass through unchanged.
  public static func httpsUpgraded(_ url: URL) -> URL {
    guard url.scheme?.lowercased() == "http",
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return url }
    components.scheme = "https"
    return components.url ?? url
  }
}
