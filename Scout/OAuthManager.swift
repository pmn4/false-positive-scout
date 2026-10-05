import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

// "It ain't hard to tell, I excel, then prevail" ~Nas (probably)
// OAuth 2.1 flow with PKCE for Roboflow authentication

class OAuthManager: NSObject, ObservableObject {
    static let shared = OAuthManager()
    
    @Published var isAuthenticated = false
    
    // OAuth configuration
    private let authorizationEndpoint = "https://app.roboflow.com/oauth/authorize"
    private let tokenEndpoint = "https://app.roboflow.com/oauth/token"
    private let validateEndpoint = "https://app.roboflow.com/oauth/validate"
    
    // Client ID placeholder - Patrick will paste from Roboflow OAuth app
    private let clientId = "YOUR_ROBOFLOW_OAUTH_CLIENT_ID"
    
    // Redirect URI (https:// for Universal Links / Associated Domains)
    // Roboflow requires https:// (or http:// for localhost only)
    // Patrick can use this GitHub Pages URL or register his own domain
    private let redirectURI = "https://pmn4.github.io/false-positive-scout/oauth/callback"
    
    // Required OAuth scopes for Scout's functionality
    private let scopes = [
        "workspace:read",   // List workspaces
        "project:read",     // List projects
        "version:read",     // List model versions for on-device picker
        "image:create",     // Upload images
        "image:read",       // Read uploaded images
        "image:tag",        // Tag uploads (e.g. "scout")
        "image:annotate",   // Annotate as null
        "batch:create",     // Create annotation batches (groups uploaded images)
        "batch:read"        // Read batch info
        // "batch:admin-read"  // Optional: read Annotation Board batches (pending confirmation)
        // "folder:read"       // Optional: project folder tree (pending confirmation)
    ]
    
    // Keychain keys
    private let accessTokenKey = "scout_oauth_access_token"
    private let refreshTokenKey = "scout_oauth_refresh_token"
    private let tokenExpiryKey = "scout_oauth_token_expiry"
    
    private var authSession: ASWebAuthenticationSession?
    
    // PKCE session state (in-memory, not persisted)
    private var currentVerifier: String?
    private var currentState: String?
    
    override private init() {
        super.init()
        checkAuthenticationStatus()
    }
    
    // MARK: - Public Methods
    
    func signIn() async throws {
        // Generate PKCE pair
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        let state = generateState()
        
        // Store in memory for this session round-trip
        currentVerifier = verifier
        currentState = state
        
        // Build authorization URL
        var components = URLComponents(string: authorizationEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        
        guard let authURL = components.url else {
            throw OAuthError.invalidURL
        }
        
        // Start web authentication session
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                self.authSession = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: "https"
                ) { callbackURL, error in
                    if let error = error {
                        continuation.resume(throwing: OAuthError.authorizationFailed(error.localizedDescription))
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
                
                // start() returns false if session couldn't be started
                if self.authSession?.start() == false {
                    // Clear PKCE session state
                    self.currentVerifier = nil
                    self.currentState = nil
                    continuation.resume(throwing: OAuthError.authorizationFailed("Failed to start authentication session"))
                }
            }
        }
    }
    
    func signOut() {
        // Clear tokens from keychain
        deleteFromKeychain(key: accessTokenKey)
        deleteFromKeychain(key: refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: tokenExpiryKey)
        
        DispatchQueue.main.async {
            self.isAuthenticated = false
        }
    }
    
    func getAccessToken() async throws -> String {
        // Check if we have a valid access token
        if let token = getFromKeychain(key: accessTokenKey),
           let expiryTimeInterval = UserDefaults.standard.object(forKey: tokenExpiryKey) as? TimeInterval {
            let expiryDate = Date(timeIntervalSince1970: expiryTimeInterval)
            
            // If token expires in more than 5 minutes, use it
            if expiryDate.timeIntervalSinceNow > 300 {
                return token
            }
        }
        
        // Try to refresh the token (calls signOut if refresh fails)
        do {
            try await refreshAccessToken()
        } catch OAuthError.noRefreshToken {
            // No refresh token available - clear stale session
            await MainActor.run {
                signOut()
            }
            throw OAuthError.noRefreshToken
        }
        
        guard let token = getFromKeychain(key: accessTokenKey) else {
            throw OAuthError.noAccessToken
        }
        
        return token
    }
    
    // MARK: - Private Methods
    
    private func handleCallback(_ url: URL) async throws {
        // Parse callback URL for code and state
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            throw OAuthError.invalidCallbackURL
        }
        
        guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
            // Check for error
            if let error = queryItems.first(where: { $0.name == "error" })?.value {
                throw OAuthError.authorizationFailed(error)
            }
            throw OAuthError.noAuthorizationCode
        }
        
        // Verify state
        let receivedState = queryItems.first(where: { $0.name == "state" })?.value
        guard receivedState == currentState else {
            currentVerifier = nil
            currentState = nil
            throw OAuthError.stateMismatch
        }
        
        // Get stored verifier from memory
        guard let verifier = currentVerifier else {
            currentVerifier = nil
            currentState = nil
            throw OAuthError.noCodeVerifier
        }
        
        // Exchange code for tokens
        try await exchangeCodeForTokens(code: code, verifier: verifier)
        
        // Clean up session state
        currentVerifier = nil
        currentState = nil
    }
    
    private func exchangeCodeForTokens(code: String, verifier: String) async throws {
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        // For public clients (native iOS), client_secret is not required when using PKCE
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
        
        // Parse token response
        let decoder = JSONDecoder()
        let tokenResponse = try decoder.decode(TokenResponse.self, from: data)
        
        // Store tokens securely in keychain
        saveToKeychain(key: accessTokenKey, value: tokenResponse.access_token)
        if let refreshToken = tokenResponse.refresh_token {
            saveToKeychain(key: refreshTokenKey, value: refreshToken)
        }
        
        // Calculate and store expiry time (access tokens valid for 1 hour)
        let expiryDate = Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in ?? 3600))
        UserDefaults.standard.set(expiryDate.timeIntervalSince1970, forKey: tokenExpiryKey)
        
        DispatchQueue.main.async {
            self.isAuthenticated = true
        }
    }
    
    private func refreshAccessToken() async throws {
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
            // Refresh token expired or invalid, need to sign in again
            signOut()
            throw OAuthError.refreshFailed
        }
        
        let decoder = JSONDecoder()
        let tokenResponse = try decoder.decode(TokenResponse.self, from: data)
        
        // Update tokens
        saveToKeychain(key: accessTokenKey, value: tokenResponse.access_token)
        if let newRefreshToken = tokenResponse.refresh_token {
            saveToKeychain(key: refreshTokenKey, value: newRefreshToken)
        }
        
        let expiryDate = Date().addingTimeInterval(TimeInterval(tokenResponse.expires_in ?? 3600))
        UserDefaults.standard.set(expiryDate.timeIntervalSince1970, forKey: tokenExpiryKey)
    }
    
    private func checkAuthenticationStatus() {
        // Check if we have a usable OAuth session (access token + refresh token OR valid expiry)
        // Don't report "authenticated" if we only have a stale access token blob
        let hasAccessToken = getFromKeychain(key: accessTokenKey) != nil
        let hasRefreshToken = getFromKeychain(key: refreshTokenKey) != nil
        let hasExpiry = UserDefaults.standard.object(forKey: tokenExpiryKey) != nil
        
        // Consider authenticated only if we have access token AND (refresh token OR expiry tracking)
        let isUsableSession = hasAccessToken && (hasRefreshToken || hasExpiry)
        
        DispatchQueue.main.async {
            self.isAuthenticated = isUsableSession
        }
    }
    
    // MARK: - PKCE Methods
    
    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    
    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    
    private func generateState() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    
    // MARK: - Form URL Encoding
    
    private func formURLEncode(_ params: [String: String]) -> String {
        // Proper form-urlencoded: percent-encode all but unreserved chars
        return params
            .map { key, value in
                let encodedKey = percentEncode(key)
                let encodedValue = percentEncode(value)
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }
    
    private func percentEncode(_ string: String) -> String {
        // RFC 3986 unreserved = ALPHA / DIGIT / "-" / "." / "_" / "~"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
    
    // MARK: - Keychain Methods
    
    private func saveToKeychain(key: String, value: String) {
        let data = Data(value.utf8)
        
        // Delete query: only class + account (no value)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        // Add query: class + account + value + accessibility
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

// MARK: - ASWebAuthenticationPresentationContextProviding

extension OAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first else {
            return ASPresentationAnchor()
        }
        return window
    }
}

// MARK: - Models

struct TokenResponse: Codable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
    let token_type: String
}

// MARK: - Errors

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
    case refreshFailed
    
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
            return "No access token available. Please sign in."
        case .noRefreshToken:
            return "No refresh token available. Please sign in again."
        case .refreshFailed:
            return "Session expired. Please sign in again."
        }
    }
}
