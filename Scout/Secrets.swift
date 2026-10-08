import Foundation

/// Optional local overrides from a bundled `Secrets.plist`.
/// Copy `Config/Secrets.plist.example` → `Config/Secrets.plist` (gitignored) if you want defaults.
/// The file is optional; builds succeed without it.
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

    /// Optional override for the public OAuth client ID (default is baked into OAuthManager).
    static var roboflowOAuthClientID: String? { string("ROBOFLOW_OAUTH_CLIENT_ID") }

    /// Optional default Roboflow workspace slug for first-run model picker.
    static var roboflowWorkspace: String? { string("ROBOFLOW_WORKSPACE") }

    /// Optional default Roboflow project id (`workspace/project` or project slug).
    static var roboflowProject: String? { string("ROBOFLOW_PROJECT") }
}
