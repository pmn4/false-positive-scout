import Foundation
import AuthenticationServices
import CryptoKit
import UIKit
import Security

// "It ain't hard to tell, I excel, then prevail" ~Nas (probably)
// OAuth 2.1 + PKCE (public client, no secret) for Log in with Roboflow

class OAuthManager: NSObject, ObservableObject {
    static let shared = OAuthManager()

    @Published var isAuthenticated = false
    /// Workspace slug from `/oauth/validate` (or API root), when known.
    @Published var workspaceURL: String?

    private let authorizationEndpoint = "https://app.roboflow.com/oauth/authorize"
    private let tokenEndpoint = "https://app.roboflow.com/oauth/token"
    private let validateEndpoint = "https://app.roboflow.com/oauth/validate"
    private let revokeEndpoint = "https://app.roboflow.com/oauth/revoke"

    /// Public DCR client for False Positive Scout. Overridable via Secrets.plist.
    private static let defaultClientId = "780dc865-a12a-47f1-bf41-5515a344474d"
    private var clientId: String {
        Secrets.roboflowOAuthClientID ?? Self.defaultClientId
    }

    /// Custom URL scheme registered in Info.plist (no HTTPS relay).
    private let redirectURI = "scout://oauth/callback"

    private let scopes = [
        "workspace:read",
        "project:read",
        "version:read",
        "image:create",
        "image:read",
        "image:tag",
        "image:annotate",
        "batch:create",
        "batch:read",
        "offline_access"
    ]

    private let accessTokenKey = "scout_oauth_access_token"
    private let refreshTokenKey = "scout_oauth_refresh_token"
    private let tokenExpiryKey = "scout_oauth_token_expiry"
    private let workspaceKey = "scout_oauth_workspace_url"
    private let legacyAPIKeyMigratedFlag = "scout_legacy_api_key_purged_v1"

    private var authSession: ASWebAuthenticationSession?
    private var currentVerifier: String?
    private var currentState: String?

    private var refreshTask: Task<Void, Error>?
    private var refreshTaskId: UUID?
    private let refreshLock = NSLock()
    private var sessionGeneration = 0

    override private init() {
        super.init()
        purgeLegacyAPIKeyIfNeeded()
        if let saved = UserDefaults.standard.string(forKey: workspaceKey), !saved.isEmpty {
            workspaceURL = saved
        }
        checkAuthenticationStatus()
    }

    // MARK: - Public

    func signIn() async throws {
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        let state = generateState()

        currentVerifier = verifier
        currentState = state

        var components = URLComponents(string: authorizationEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let authURL = components.url else {
            throw OAuthError.invalidURL
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                self.authSession = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: "scout"
                ) { callbackURL, error in
                    if let error = error {
                        self.currentVerifier = nil
                        self.currentState = nil
                        let nsError = error as NSError
                        if nsError.domain == ASWebAuthenticationSessionErrorDomain,
                           nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                            continuation.resume(throwing: OAuthError.authorizationFailed("Sign in canceled"))
                        } else {
                            continuation.resume(throwing: OAuthError.authorizationFailed(error.localizedDescription))
                        }
                        return
                    }

                    guard let callbackURL = callbackURL else {
                        continuation.resume(throwing: OAuthError.noCallbackURL)
                        return
                    }

                    Task {
                        do {
                            try await self.handleCallback(callbackURL)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }

                self.authSession?.presentationContextProvider = self
                self.authSession?.prefersEphemeralWebBrowserSession = false

                if self.authSession?.start() != true {
                    self.currentVerifier = nil
                    self.currentState = nil
                    continuation.resume(throwing: OAuthError.authorizationFailed("Failed to start authentication session"))
                }
            }
        }
    }

    /// Revokes tokens at Roboflow, then clears Keychain / local state.
    func signOut() async {
        let access = getFromKeychain(key: accessTokenKey)
        let refresh = getFromKeychain(key: refreshTokenKey)

        if let refresh {
            await revokeToken(refresh, hint: "refresh_token")
        }
        if let access {
            await revokeToken(access, hint: "access_token")
        }

        refreshLock.lock()
        sessionGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskId = nil
        refreshLock.unlock()

        deleteFromKeychain(key: accessTokenKey)
        deleteFromKeychain(key: refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: tokenExpiryKey)
        UserDefaults.standard.removeObject(forKey: workspaceKey)

        await MainActor.run {
            self.workspaceURL = nil
            self.isAuthenticated = false
        }
    }

    /// Returns a valid access token, refreshing when expiry is within 5 minutes.
    func getAccessToken() async throws -> String {
        if let token = getFromKeychain(key: accessTokenKey),
           let expiryTimeInterval = UserDefaults.standard.object(forKey: tokenExpiryKey) as? TimeInterval {
            let expiryDate = Date(timeIntervalSince1970: expiryTimeInterval)
            if expiryDate.timeIntervalSinceNow > 300 {
                return token
            }
        }

        do {
            try await refreshAccessToken(force: true)
        } catch OAuthError.noRefreshToken {
            await signOut()
            throw OAuthError.noRefreshToken
        }

        guard let token = getFromKeychain(key: accessTokenKey) else {
            throw OAuthError.noAccessToken
        }
        return token
    }

    /// Force a refresh (e.g. after HTTP 401). Serialized with other refreshes.
    func forceRefreshAccessToken() async throws {
        try await refreshAccessToken(force: true)
    }

    /// Perform an authenticated request. On 401, force-refresh once and retry.
    func authorizedData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var first = request
        let token = try await getAccessToken()
        first.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: first)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.invalidResponse
        }
        if http.statusCode != 401 {
            return (data, http)
        }

        try await forceRefreshAccessToken()
        var retry = request
        let newToken = try await getAccessToken()
        retry.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
        let (data2, response2) = try await URLSession.shared.data(for: retry)
        guard let http2 = response2 as? HTTPURLResponse else {
            throw OAuthError.invalidResponse
        }
        return (data2, http2)
    }

    /// Authenticated download (follows same 401 → refresh → retry once).
    func authorizedDownload(from url: URL) async throws -> (URL, HTTPURLResponse) {
        var request = URLRequest(url: url)
        let token = try await getAccessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.invalidResponse
        }
        if http.statusCode != 401 {
            return (tempURL, http)
        }

        try? FileManager.default.removeItem(at: tempURL)
        try await forceRefreshAccessToken()
        var retry = URLRequest(url: url)
        let newToken = try await getAccessToken()
        retry.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
        let (tempURL2, response2) = try await URLSession.shared.download(for: retry)
        guard let http2 = response2 as? HTTPURLResponse else {
            throw OAuthError.invalidResponse
        }
        return (tempURL2, http2)
    }

    // MARK: - Callback / tokens

    private func handleCallback(_ url: URL) async throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            throw OAuthError.invalidCallbackURL
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
            if let error = queryItems.first(where: { $0.name == "error" })?.value {
                let errorDescription = queryItems.first(where: { $0.name == "error_description" })?.value
                let friendlyMessage: String
                if error == "access_denied" {
                    friendlyMessage = "Sign in canceled or access denied"
                } else if let description = errorDescription {
                    friendlyMessage = "\(error): \(description)"
                } else {
                    friendlyMessage = error
                }
                throw OAuthError.authorizationFailed(friendlyMessage)
            }
            throw OAuthError.noAuthorizationCode
        }

        let receivedState = queryItems.first(where: { $0.name == "state" })?.value
        guard receivedState == currentState else {
            currentVerifier = nil
            currentState = nil
            throw OAuthError.stateMismatch
        }

        guard let verifier = currentVerifier else {
            currentVerifier = nil
            currentState = nil
            throw OAuthError.noCodeVerifier
        }

        try await exchangeCodeForTokens(code: code, verifier: verifier)
        currentVerifier = nil
        currentState = nil
    }

    private func exchangeCodeForTokens(code: String, verifier: String) async throws {
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "grant_type": "authorization_code",
            "client_id": clientId,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ]
        request.httpBody = formURLEncode(bodyParams).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Token exchange failed"
            throw OAuthError.tokenExchangeFailed(errorMessage)
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        saveToKeychain(key: accessTokenKey, value: tokenResponse.access_token)
        if let refreshToken = tokenResponse.refresh_token {
            saveToKeychain(key: refreshTokenKey, value: refreshToken)
        }

        let expiryDate = Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in ?? 86400))
        UserDefaults.standard.set(expiryDate.timeIntervalSince1970, forKey: tokenExpiryKey)

        await MainActor.run { self.isAuthenticated = true }
        await refreshWorkspaceFromValidate()
    }

    private func refreshAccessToken(force: Bool) async throws {
        _ = force // always refresh when called; callers gate on expiry

        refreshLock.lock()
        if let existingTask = refreshTask {
            refreshLock.unlock()
            return try await existingTask.value
        }

        let expectedGeneration = sessionGeneration
        let taskId = UUID()

        let task = Task<Void, Error> {
            defer {
                refreshLock.lock()
                if refreshTaskId == taskId {
                    refreshTask = nil
                    refreshTaskId = nil
                }
                refreshLock.unlock()
            }

            guard let refreshToken = getFromKeychain(key: refreshTokenKey) else {
                throw OAuthError.noRefreshToken
            }

            var request = URLRequest(url: URL(string: tokenEndpoint)!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let bodyParams = [
                "grant_type": "refresh_token",
                "client_id": clientId,
                "refresh_token": refreshToken
            ]
            request.httpBody = formURLEncode(bodyParams).data(using: .utf8)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OAuthError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                refreshLock.lock()
                let currentGen = sessionGeneration
                refreshLock.unlock()

                let shouldSignOut = (httpResponse.statusCode == 400 || httpResponse.statusCode == 401)
                    && currentGen == expectedGeneration
                if shouldSignOut {
                    await signOut()
                }
                if currentGen != expectedGeneration {
                    throw CancellationError()
                }
                throw OAuthError.refreshFailed(signedOut: shouldSignOut)
            }

            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

            refreshLock.lock()
            defer { refreshLock.unlock() }
            guard sessionGeneration == expectedGeneration else {
                throw CancellationError()
            }

            saveToKeychain(key: accessTokenKey, value: tokenResponse.access_token)
            // Refresh tokens rotate — always store the new one when present.
            if let newRefreshToken = tokenResponse.refresh_token {
                saveToKeychain(key: refreshTokenKey, value: newRefreshToken)
            }

            let expiryDate = Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in ?? 86400))
            UserDefaults.standard.set(expiryDate.timeIntervalSince1970, forKey: tokenExpiryKey)
        }

        refreshTask = task
        refreshTaskId = taskId
        refreshLock.unlock()
        try await task.value
    }

    private func refreshWorkspaceFromValidate() async {
        do {
            var request = URLRequest(url: URL(string: validateEndpoint)!)
            let (data, http) = try await authorizedData(for: request)
            guard http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            let slug = (json["workspace_url"] as? String)
                ?? (json["workspace"] as? String)
            if let slug, !slug.isEmpty {
                UserDefaults.standard.set(slug, forKey: workspaceKey)
                await MainActor.run { self.workspaceURL = slug }
            }
        } catch {
            // Non-fatal: workspace can still come from API root later.
        }
    }

    private func revokeToken(_ token: String, hint: String) async {
        var request = URLRequest(url: URL(string: revokeEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "token": token,
            "token_type_hint": hint,
            "client_id": clientId
        ]
        request.httpBody = formURLEncode(body).data(using: .utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    private func checkAuthenticationStatus() {
        let hasAccessToken = getFromKeychain(key: accessTokenKey) != nil
        let hasRefreshToken = getFromKeychain(key: refreshTokenKey) != nil
        let hasExpiry = UserDefaults.standard.object(forKey: tokenExpiryKey) != nil
        let isUsableSession = hasAccessToken && (hasRefreshToken || hasExpiry)

        if Thread.isMainThread {
            self.isAuthenticated = isUsableSession
        } else {
            DispatchQueue.main.sync {
                self.isAuthenticated = isUsableSession
            }
        }
    }

    private func purgeLegacyAPIKeyIfNeeded() {
        guard UserDefaults.standard.bool(forKey: legacyAPIKeyMigratedFlag) == false else { return }
        KeychainHelper.deleteAPIKey()
        UserDefaults.standard.set(true, forKey: legacyAPIKeyMigratedFlag)
    }

    // MARK: - PKCE

    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return base64URLEncode(Data(buffer))
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(hash))
    }

    private func generateState() -> String {
        var buffer = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return base64URLEncode(Data(buffer))
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func formURLEncode(_ params: [String: String]) -> String {
        params.map { key, value in
            "\(percentEncode(key))=\(percentEncode(value))"
        }.joined(separator: "&")
    }

    private func percentEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    // MARK: - Keychain

    private func saveToKeychain(key: String, value: String) {
        let data = Data(value.utf8)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func getFromKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private func deleteFromKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

extension OAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first else {
            return ASPresentationAnchor()
        }
        return window
    }
}

struct TokenResponse: Codable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
    let token_type: String?
}

enum OAuthError: LocalizedError {
    case invalidURL
    case authorizationFailed(String)
    case noCallbackURL
    case invalidCallbackURL
    case noAuthorizationCode
    case stateMismatch
    case noCodeVerifier
    case tokenExchangeFailed(String)
    case invalidResponse
    case noAccessToken
    case noRefreshToken
    case refreshFailed(signedOut: Bool)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid OAuth URL"
        case .authorizationFailed(let message):
            return "Authorization failed: \(message)"
        case .noCallbackURL:
            return "No callback URL received"
        case .invalidCallbackURL:
            return "Invalid callback URL format"
        case .noAuthorizationCode:
            return "No authorization code received"
        case .stateMismatch:
            return "Security check failed (state mismatch)"
        case .noCodeVerifier:
            return "Missing code verifier"
        case .tokenExchangeFailed(let message):
            return "Token exchange failed: \(message)"
        case .invalidResponse:
            return "Invalid response from server"
        case .noAccessToken:
            return "No access token available. Please log in."
        case .noRefreshToken:
            return "No refresh token available. Please log in again."
        case .refreshFailed(let signedOut):
            if signedOut {
                return "Session expired. Please log in again."
            }
            return "Token refresh failed. Please try again."
        }
    }
}
