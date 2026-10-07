import Foundation
import UIKit

// "I never sleep, 'cause sleep is the cousin of death" - Nas (probably)
// Service for calling Roboflow inference API

// "Upload progress like I'm on a mission" ~Nas (probably)
// Progress tracking for bulk operations
struct UploadProgress {
    var current: Int
    var total: Int
    var currentImageName: String
    
    var percentage: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }
}

// "Born alone, die alone, no crew to keep my crown" ~Nas (probably)
// Workspace and project models for OAuth-based project selection
struct Workspace: Codable, Identifiable, Hashable {
    let url: String
    let name: String
    let members: Int?
    
    var id: String { url }
}

struct Project: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let workspace: String?
}

class RoboflowService {
    static let shared = RoboflowService()
    
    private init() {}
    
    // MARK: - Auth Strategy
    
    // Determine auth method: prefer OAuth, fall back to API key
    enum AuthMethod {
        case oauth(token: String)
        case apiKey(key: String)
        case none
    }
    
    private func getAuthMethod(apiKey: String? = nil) async throws -> AuthMethod {
        // If OAuth is active (signed in), try it first
        if OAuthManager.shared.isAuthenticated {
            do {
                // Propagate OAuth token failures (will trigger sign out if expired)
                let token = try await OAuthManager.shared.getAccessToken()
                return .oauth(token: token)
            } catch {
                // Re-check isAuthenticated: getAccessToken may have signedOut on refresh 400/401
                // If signed out, fall through to API key; if still authenticated (5xx/429), rethrow
                if !OAuthManager.shared.isAuthenticated {
                    // Fall through to API key path (self-signOut on expired refresh token)
                } else {
                    // Still authenticated: temporary error (5xx, 429), propagate
                    throw error
                }
            }
        }
        
        // Only use API key when NOT signed in with OAuth (or after self-signOut)
        if let key = apiKey, !key.isEmpty {
            return .apiKey(key: key)
        }
        
        return .none
    }
    
    // MARK: - Workspace & Project Discovery (OAuth or API key)
    
    // List all workspaces accessible to the authenticated user
    func listWorkspaces(apiKey: String? = nil) async throws -> [Workspace] {
        let auth = try await getAuthMethod(apiKey: apiKey)
        
        var url = URL(string: "https://api.roboflow.com/")!
        var request = URLRequest(url: url)
        
        switch auth {
        case .oauth(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .apiKey(let key):
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "api_key", value: key)]
            url = components.url!
            request.url = url
        case .none:
            throw RoboflowError.authenticationRequired
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RoboflowError.apiError(statusCode: 0, message: "Invalid response from server")
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw RoboflowError.apiError(statusCode: httpResponse.statusCode, message: "Failed to fetch workspaces: \(errorBody)")
        }
        
        let decoder = JSONDecoder()
        
        // SIWR/docs return {"workspace":"slug",...}, not {"workspaces":[...]}
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Try single workspace string (SIWR response)
            if let workspaceSlug = json["workspace"] as? String {
                return [Workspace(url: workspaceSlug, name: workspaceSlug, members: 1)]
            }
            // Try array format (if it exists)
            if let workspacesArray = json["workspaces"] as? [[String: Any]] {
                let workspaces = workspacesArray.compactMap { dict -> Workspace? in
                    guard let url = dict["url"] as? String else { return nil }
                    let name = dict["name"] as? String ?? url
                    let members = dict["members"] as? Int ?? 1
                    return Workspace(url: url, name: name, members: members)
                }
                return workspaces
            }
        }
        
        throw RoboflowError.apiError(statusCode: httpResponse.statusCode, message: "No workspace found in API response")
    }
    
    // List all projects in a workspace
    func listProjects(workspace: String, apiKey: String? = nil) async throws -> [Project] {
        let auth = try await getAuthMethod(apiKey: apiKey)
        
        var url = URL(string: "https://api.roboflow.com/\(workspace)")!
        var request = URLRequest(url: url)
        
        switch auth {
        case .oauth(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .apiKey(let key):
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "api_key", value: key)]
            url = components.url!
            request.url = url
        case .none:
            throw RoboflowError.authenticationRequired
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RoboflowError.apiError(statusCode: 0, message: "Failed to fetch projects")
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw RoboflowError.apiError(statusCode: httpResponse.statusCode, message: "Failed to fetch projects: \(errorBody)")
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projectsDict = json["workspace"] as? [String: Any],
           let projectsArray = projectsDict["projects"] as? [[String: Any]] {
            
            let projects = projectsArray.compactMap { dict -> Project? in
                guard let id = dict["id"] as? String,
                      let name = dict["name"] as? String else {
                    return nil
                }
                return Project(id: id, name: name, workspace: workspace)
            }
            return projects
        }
        
        return []
    }
    
    
    // MARK: - Upload & Annotate (OAuth Bearer token)
    
    // Default tag for Scout uploads (configurable)
    static let defaultUploadTag = "scout"
    
    // Upload image to Roboflow project using OAuth or API key
    func uploadImage(
        image: UIImage,
        imageName: String,
        project: String,
        tag: String? = defaultUploadTag,
        batchName: String? = nil,
        apiKey: String? = nil
    ) async throws -> String {
        let auth = try await getAuthMethod(apiKey: apiKey)
        
        let token: String
        switch auth {
        case .oauth(let oauthToken):
            token = oauthToken
        case .apiKey(let key):
            return try await uploadImageWithAPIKey(
                image: image,
                imageName: imageName,
                project: project,
                tag: tag,
                batchName: batchName,
                apiKey: key
            )
        case .none:
            throw RoboflowError.authenticationRequired
        }
        
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw RoboflowError.imageConversionFailed
        }
        
        let base64String = imageData.base64EncodedString()
        
        // Extract project slug from qualified ID (ws/proj -> proj)
        let projectSlug = project.split(separator: "/").last.map(String.init) ?? project
        
        // Upload using Bearer token, with tag and batch as query params
        var components = URLComponents(string: "https://api.roboflow.com/dataset/\(projectSlug)/upload")!
        var queryItems = [
            URLQueryItem(name: "name", value: imageName),
            URLQueryItem(name: "split", value: "train")
        ]
        
        if let tag = tag, !tag.isEmpty {
            queryItems.append(URLQueryItem(name: "tag", value: tag))
        }
        
        if let batchName = batchName, !batchName.isEmpty {
            queryItems.append(URLQueryItem(name: "batch", value: batchName))
        }
        
        components.queryItems = queryItems
        
        guard let uploadURL = components.url else {
            throw RoboflowError.invalidURL
        }
        
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        request.httpBody = base64String.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Upload failed"
            throw RoboflowError.uploadFailed(message: errorMessage)
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let imageId = json["id"] as? String {
            return imageId
        }
        
        throw RoboflowError.uploadFailed(message: "No image ID returned")
    }
    
    // Upload image using API key (fallback when not signed in)
    private func uploadImageWithAPIKey(
        image: UIImage,
        imageName: String,
        project: String,
        tag: String?,
        batchName: String?,
        apiKey: String
    ) async throws -> String {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw RoboflowError.imageConversionFailed
        }
        
        let base64String = imageData.base64EncodedString()
        
        // Extract project slug from qualified ID
        let projectSlug = project.split(separator: "/").last.map(String.init) ?? project
        
        var components = URLComponents(string: "https://api.roboflow.com/dataset/\(projectSlug)/upload")!
        var queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "name", value: imageName),
            URLQueryItem(name: "split", value: "train")
        ]
        
        if let tag = tag, !tag.isEmpty {
            queryItems.append(URLQueryItem(name: "tag", value: tag))
        }
        
        if let batchName = batchName, !batchName.isEmpty {
            queryItems.append(URLQueryItem(name: "batch", value: batchName))
        }
        
        components.queryItems = queryItems
        
        guard let uploadURL = components.url else {
            throw RoboflowError.invalidURL
        }
        
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = base64String.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Upload failed"
            throw RoboflowError.uploadFailed(message: errorMessage)
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let imageId = json["id"] as? String {
            return imageId
        }
        
        throw RoboflowError.uploadFailed(message: "No image ID returned")
    }
    
    
    // Annotate image as null using COCO JSON format (OAuth or API key).
    // Matches Roboflow Python SDK: fake annotation with unmatched image_id so the
    // image is accepted as COCO but ends up with zero boxes (a null/negative example).
    func annotateAsNull(
        imageId: String,
        imageName: String,
        imageWidth: Int,
        imageHeight: Int,
        project: String,
        apiKey: String? = nil
    ) async throws {
        let auth = try await getAuthMethod(apiKey: apiKey)
        
        // file_name must match the `name` query used on upload (includes extension, e.g. .jpg)
        let cocoJson: [String: Any] = [
            "info": [
                "description": "Scout null frame"
            ],
            "licenses": [],
            "categories": [
                [
                    "id": 0,
                    "name": "null",
                    "supercategory": "none"
                ]
            ],
            "images": [
                [
                    "id": 0,
                    "file_name": imageName,
                    "width": imageWidth,
                    "height": imageHeight
                ]
            ],
            // SDK workaround: non-empty annotations required for COCO recognition,
            // but image_id does not match any image → zero boxes on this image.
            "annotations": [
                [
                    "id": 999999999,
                    "image_id": 999999999,
                    "category_id": 0,
                    "area": 1,
                    "bbox": [0, 0, 1, 1],
                    "segmentation": [],
                    "iscrowd": 0
                ]
            ]
        ]
        
        guard let cocoJsonData = try? JSONSerialization.data(withJSONObject: cocoJson),
              let cocoJsonString = String(data: cocoJsonData, encoding: .utf8) else {
            throw RoboflowError.annotationFailed(message: "Failed to create COCO JSON")
        }
        
        let projectSlug = project.split(separator: "/").last.map(String.init) ?? project
        
        var components = URLComponents(string: "https://api.roboflow.com/dataset/\(projectSlug)/annotate/\(imageId)")!
        components.queryItems = [
            URLQueryItem(name: "name", value: "annotation.coco.json")
        ]
        
        if case .apiKey(let key) = auth {
            components.queryItems?.append(URLQueryItem(name: "api_key", value: key))
        } else if case .none = auth {
            throw RoboflowError.authenticationRequired
        }
        
        guard let annotateURL = components.url else {
            throw RoboflowError.invalidURL
        }
        
        var request = URLRequest(url: annotateURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if case .oauth(let token) = auth {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        let payload: [String: Any] = [
            "annotationFile": cocoJsonString,
            "labelmap": NSNull()
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RoboflowError.invalidResponse
        }
        
        let responseBody = String(data: data, encoding: .utf8) ?? ""
        
        if httpResponse.statusCode == 409 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String,
               message.contains("already annotated") {
                return
            }
            ScoutLog.decision("🔴 [ScoutNullify] 409 response: \(responseBody)")
        }
        
        guard httpResponse.statusCode == 200 else {
            ScoutLog.decision("🔴 [ScoutNullify] annotate failed status=\(httpResponse.statusCode) body=\(responseBody)")
            throw RoboflowError.annotationFailed(message: responseBody.isEmpty ? "Annotation failed" : responseBody)
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let success = json["success"] as? Bool, !success {
                ScoutLog.decision("🔴 [ScoutNullify] annotate success=false body=\(responseBody)")
                let errorMessage = json["error"] as? String ?? responseBody
                throw RoboflowError.annotationFailed(message: errorMessage.isEmpty ? "Annotation failed" : errorMessage)
            }
        }
    }
}


enum RoboflowError: LocalizedError {
    case authenticationRequired
    case imageConversionFailed
    case invalidURL
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case uploadFailed(message: String)
    case annotationFailed(message: String)
    
    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return "Please sign in with Roboflow or configure an API key in Settings"
        case .imageConversionFailed:
            return "Failed to process image"
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .apiError(let statusCode, let message):
            return "API Error (\(statusCode)): \(message)"
        case .uploadFailed(let message):
            return "Upload failed: \(message)"
        case .annotationFailed(let message):
            return "Annotation failed: \(message)"
        }
    }
}
