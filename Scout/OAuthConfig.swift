import Foundation

/// OAuth configuration - controls whether Sign in with Roboflow is available
/// 
/// OAuth works with FREE Apple Personal Team via custom URL scheme relay:
/// - Redirect URI: https://pmn4.github.io/false-positive-scout/oauth/callback
/// - Relay page immediately forwards to: scout://oauth/callback?code=...&state=...
/// - No Associated Domains capability required
/// - No apple-app-site-association file required
/// 
/// Default: OAuth enabled (preferred method)
struct OAuthConfig {
    /// Enable OAuth / Sign in with Roboflow
    /// 
    /// Set to `true` to enable OAuth authentication alongside API key
    /// Requires paid Apple Developer Program and Associated Domains setup
    /// 
    /// Default: `true` (OAuth via custom URL scheme relay, works with free Apple Personal Team)
    static let isEnabled = true
}
