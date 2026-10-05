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
struct Workspace: Codable, Identifiable {
    let url: String
    let name: String
    let members: Int?
    
    var id: String { url }
}

struct Project: Codable, Identifiable {
    let id: String
    let name: String
    let workspace: String?
}

class RoboflowService {
    static let shared = RoboflowService()
    
    private init() {}
    
    // MARK: - OAuth-based methods
    
    // List all workspaces accessible to the authenticated user
    func listWorkspaces() async throws -> [Workspace] {
        let accessToken = try await OAuthManager.shared.getAccessToken()
        
        let url = URL(string: "https://api.roboflow.com/")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw RoboflowError.apiError(statusCode: 0, message: "Failed to fetch workspaces")
        }
        
        let decoder = JSONDecoder()
        let workspaceResponse = try decoder.decode([String: [Workspace]].self, from: data)
        return workspaceResponse["workspaces"] ?? []
    }
    
    // List all projects in a workspace
    func listProjects(workspace: String) async throws -> [Project] {
        let accessToken = try await OAuthManager.shared.getAccessToken()
        
        let url = URL(string: "https://api.roboflow.com/\(workspace)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw RoboflowError.apiError(statusCode: 0, message: "Failed to fetch projects")
        }
        
        let decoder = JSONDecoder()
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
    
    // Upload image to Roboflow project using OAuth access token
    func uploadImage(
        image: UIImage,
        imageName: String,
        project: String,
        tag: String? = defaultUploadTag,
        batchName: String? = nil
    ) async throws -> String {
        let accessToken = try await OAuthManager.shared.getAccessToken()
        
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw RoboflowError.imageConversionFailed
        }
        
        let base64String = imageData.base64EncodedString()
        
        // Upload using Bearer token, with optional batch grouping
        var components = URLComponents(string: "https://api.roboflow.com/dataset/\(project)/upload")!
        var queryItems = [
            URLQueryItem(name: "name", value: imageName),
            URLQueryItem(name: "split", value: "train")
        ]
        
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
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        request.httpBody = base64String.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Upload failed"
            throw RoboflowError.uploadFailed(message: errorMessage)
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let imageId = json["id"] as? String {
            
            // Tag the uploaded image if tag is provided
            if let tag = tag, !tag.isEmpty {
                try? await tagImage(imageId: imageId, project: project, tag: tag)
            }
            
            return imageId
        }
        
        throw RoboflowError.uploadFailed(message: "No image ID returned")
    }
    
    // Tag an uploaded image (using image:tag scope)
    private func tagImage(imageId: String, project: String, tag: String) async throws {
        let accessToken = try await OAuthManager.shared.getAccessToken()
        
        let url = URL(string: "https://api.roboflow.com/dataset/\(project)/\(imageId)/tag?tag=\(tag)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            // Tagging failure is non-critical, just log it
            print("Warning: Failed to tag image \(imageId) with tag '\(tag)'")
        }
    }
    
    // Annotate image as null using COCO JSON format with OAuth Bearer token
    // Matches Roboflow CLI/SDK mechanism for marking null/negative examples
    func annotateAsNull(
        imageId: String,
        imageName: String,
        imageWidth: Int,
        imageHeight: Int,
        project: String
    ) async throws {
        let accessToken = try await OAuthManager.shared.getAccessToken()
        
        // Build COCO JSON with image but no annotations (null example)
        let cocoJson: [String: Any] = [
            "images": [
                [
                    "id": 0,
                    "file_name": imageName,
                    "width": imageWidth,
                    "height": imageHeight
                ]
            ],
            "annotations": [],
            "categories": []
        ]
        
        guard let cocoJsonData = try? JSONSerialization.data(withJSONObject: cocoJson),
              let cocoJsonString = String(data: cocoJsonData, encoding: .utf8) else {
            throw RoboflowError.annotationFailed(message: "Failed to create COCO JSON")
        }
        
        var components = URLComponents(string: "https://api.roboflow.com/dataset/\(project)/annotate/\(imageId)")!
        components.queryItems = [
            URLQueryItem(name: "name", value: "\(imageName).coco.json")
        ]
        
        guard let annotateURL = components.url else {
            throw RoboflowError.invalidURL
        }
        
        var request = URLRequest(url: annotateURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        let payload: [String: Any] = [
            "annotationFile": cocoJsonString,
            "labelmap": [:]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RoboflowError.invalidResponse
        }
        
        if httpResponse.statusCode == 409 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String,
               message.contains("already annotated") {
                return
            }
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Annotation failed"
            throw RoboflowError.annotationFailed(message: errorMessage)
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let success = json["success"] as? Bool, !success {
                let errorMessage = json["error"] as? String ?? "Annotation failed"
                throw RoboflowError.annotationFailed(message: errorMessage)
            }
        }
    }
}

enum RoboflowError: LocalizedError {
    case imageConversionFailed
    case invalidURL
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case uploadFailed(message: String)
    case annotationFailed(message: String)
    
    var errorDescription: String? {
        switch self {
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
