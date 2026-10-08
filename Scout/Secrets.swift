import Foundation

/// Loads optional local secrets from the bundled `Secrets.plist`.
/// Real values live only in the gitignored `Config/Secrets.plist` (copied into the app at build time).
enum Secrets {
    private static let values: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any] else {
            return [:]
        }
        return dict
    }()

    private static func string(_ key: String) -> String? {
        guard let raw = values[key] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Optional default API key. In-app Settings / Keychain still wins when the user has saved a key.
    static var roboflowAPIKey: String? { string("ROBOFLOW_API_KEY") }

    /// OAuth client ID (only needed if OAuthConfig.isEnabled).
    static var roboflowOAuthClientID: String? { string("ROBOFLOW_OAUTH_CLIENT_ID") }

    /// Optional default Roboflow workspace slug for first-run model picker.
    static var roboflowWorkspace: String? { string("ROBOFLOW_WORKSPACE") }

    /// Optional default Roboflow project id (`workspace/project` or project slug).
    static var roboflowProject: String? { string("ROBOFLOW_PROJECT") }
}
