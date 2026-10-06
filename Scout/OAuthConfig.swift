import Foundation

/// OAuth configuration - controls whether Sign in with Roboflow is available
/// 
/// OAuth requires:
/// - Paid Apple Developer Program membership (Associated Domains capability)
/// - apple-app-site-association file hosted at https://pmnewell.com/.well-known/
/// - Roboflow OAuth app registered with redirect URI
/// 
/// Free Apple Personal Team: OAuth is NOT supported (no Associated Domains)
/// Default: API key authentication only
struct OAuthConfig {
    /// Enable OAuth / Sign in with Roboflow
    /// 
    /// Set to `true` to enable OAuth authentication alongside API key
    /// Requires paid Apple Developer Program and Associated Domains setup
    /// 
    /// Default: `false` (API key only, works with free Apple Personal Team)
    static let isEnabled = false
}
