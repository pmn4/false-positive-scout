import Foundation

/// OAuth configuration - controls whether Sign in with Roboflow is available
/// 
/// OAuth is currently DISABLED because Roboflow OAuth apps require a client secret
/// (client_secret_post or client_secret_basic only). No public-client / PKCE-only
/// option is available as of October 2026. We won't embed a secret or run a backend.
/// 
/// The OAuth code is kept in place for future re-enable if Roboflow adds public client support.
/// 
/// Default: API key authentication only
struct OAuthConfig {
    /// Enable OAuth / Sign in with Roboflow
    /// 
    /// Set to `true` to enable OAuth authentication alongside API key
    /// Currently disabled: Roboflow requires client secret (no public-client option)
    /// 
    /// Default: `false` (API key only)
    static let isEnabled = false
}
