import Foundation
import UIKit

// "I never sleep, 'cause sleep is the cousin of death" - Nas (probably)
// Service for Roboflow REST (Bearer OAuth only)

// "Upload progress like I'm on a mission" ~Nas (probably)
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

    static let defaultUploadTag = "scout"

    // MARK: - Workspace & Project Discovery

    func listWorkspaces() async throws -> [Workspace] {
        let request = URLRequest(url: URL(string: "https://api.roboflow.com/")!)
        let (data, http) = try await OAuthManager.shared.authorizedData(for: request)

        guard http.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw RoboflowError.apiError(statusCode: http.statusCode, message: "Failed to fetch workspaces: \(errorBody)")
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let workspaceSlug = json["workspace"] as? String {
                await MainActor.run {
                    if OAuthManager.shared.workspaceURL == nil {
                        OAuthManager.shared.workspaceURL = workspaceSlug
                    }
                }
                return [Workspace(url: workspaceSlug, name: workspaceSlug, members: 1)]
            }
            if let workspacesArray = json["workspaces"] as? [[String: Any]] {
                return workspacesArray.compactMap { dict -> Workspace? in
                    guard let url = dict["url"] as? String else { return nil }
                    let name = dict["name"] as? String ?? url
                    let members = dict["members"] as? Int ?? 1
                    return Workspace(url: url, name: name, members: members)
                }
            }
        }

        throw RoboflowError.apiError(statusCode: http.statusCode, message: "No workspace found in API response")
    }

    func listProjects(workspace: String) async throws -> [Project] {
        let request = URLRequest(url: URL(string: "https://api.roboflow.com/\(workspace)")!)
        let (data, http) = try await OAuthManager.shared.authorizedData(for: request)

        guard http.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw RoboflowError.apiError(statusCode: http.statusCode, message: "Failed to fetch projects: \(errorBody)")
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projectsDict = json["workspace"] as? [String: Any],
           let projectsArray = projectsDict["projects"] as? [[String: Any]] {
            return projectsArray.compactMap { dict -> Project? in
                guard let id = dict["id"] as? String,
                      let name = dict["name"] as? String else {
                    return nil
                }
                return Project(id: id, name: name, workspace: workspace)
            }
        }

        return []
    }

    // MARK: - Upload & Annotate

    func uploadImage(
        image: UIImage,
        imageName: String,
        project: String,
        tag: String? = defaultUploadTag,
        batchName: String? = nil
    ) async throws -> String {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw RoboflowError.imageConversionFailed
        }

        let base64String = imageData.base64EncodedString()
        let projectSlug = project.split(separator: "/").last.map(String.init) ?? project

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
        request.httpBody = base64String.data(using: .utf8)

        let (data, http) = try await OAuthManager.shared.authorizedData(for: request)

        guard http.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Upload failed"
            throw RoboflowError.uploadFailed(message: errorMessage)
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let imageId = json["id"] as? String {
            return imageId
        }

        throw RoboflowError.uploadFailed(message: "No image ID returned")
    }

    /// Annotate as null using COCO JSON (SDK fake-annotation workaround).
    func annotateAsNull(
        imageId: String,
        imageName: String,
        imageWidth: Int,
        imageHeight: Int,
        project: String
    ) async throws {
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

        guard let annotateURL = components.url else {
            throw RoboflowError.invalidURL
        }

        var request = URLRequest(url: annotateURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "annotationFile": cocoJsonString,
            "labelmap": NSNull()
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, http) = try await OAuthManager.shared.authorizedData(for: request)
        let responseBody = String(data: data, encoding: .utf8) ?? ""

        if http.statusCode == 409 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String,
               message.contains("already annotated") {
                return
            }
            ScoutLog.decision("🔴 [ScoutNullify] 409 response: \(responseBody)")
        }

        guard http.statusCode == 200 else {
            ScoutLog.decision("🔴 [ScoutNullify] annotate failed status=\(http.statusCode) body=\(responseBody)")
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
            return "Please log in with Roboflow in Settings"
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
