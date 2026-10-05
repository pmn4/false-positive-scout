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

class RoboflowService {
    static let shared = RoboflowService()
    
    private init() {}
    
    func detect(image: UIImage, config: RoboflowConfig) async throws -> [Detection] {
        guard !config.modelId.isEmpty, !config.apiKey.isEmpty else {
            throw RoboflowError.missingConfiguration
        }
        
        let parts = config.modelId.split(separator: "/")
        guard parts.count == 2 else {
            throw RoboflowError.invalidModelId
        }
        
        let workspace = String(parts[0])
        let version = String(parts[1])
        
        // Convert image to base64
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw RoboflowError.imageConversionFailed
        }
        
        let base64String = imageData.base64EncodedString()
        
        // Build URL
        var components = URLComponents(string: "https://detect.roboflow.com/\(workspace)/\(version)")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: config.apiKey),
            URLQueryItem(name: "confidence", value: String(config.confidenceThreshold))
        ]
        
        guard let url = components.url else {
            throw RoboflowError.invalidURL
        }
        
        // Create request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = base64String.data(using: .utf8)
        
        // Make request
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RoboflowError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw RoboflowError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
        
        // Decode response
        let decoder = JSONDecoder()
        let inferenceResponse = try decoder.decode(InferenceResponse.self, from: data)
        
        return inferenceResponse.predictions
    }
    
    // Upload image and annotate as null
    func uploadAndNullify(
        image: UIImage,
        imageName: String,
        workspace: String,
        project: String,
        apiKey: String
    ) async throws -> String {
        // Upload image
        let imageId = try await uploadImage(
            image: image,
            imageName: imageName,
            workspace: workspace,
            project: project,
            apiKey: apiKey
        )
        
        // Annotate as null (empty annotation)
        try await annotateAsNull(
            imageId: imageId,
            workspace: workspace,
            project: project,
            apiKey: apiKey
        )
        
        return imageId
    }
    
    private func uploadImage(
        image: UIImage,
        imageName: String,
        workspace: String,
        project: String,
        apiKey: String
    ) async throws -> String {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw RoboflowError.imageConversionFailed
        }
        
        let base64String = imageData.base64EncodedString()
        
        // Upload to Roboflow - api_key, name, split as query params
        var components = URLComponents(string: "https://api.roboflow.com/dataset/\(project)/upload")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "name", value: imageName),
            URLQueryItem(name: "split", value: "train")
        ]
        
        guard let uploadURL = components.url else {
            throw RoboflowError.invalidURL
        }
        
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        // Body is raw base64 string
        request.httpBody = base64String.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Upload failed"
            throw RoboflowError.uploadFailed(message: errorMessage)
        }
        
        // Parse response to get image ID
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let imageId = json["id"] as? String {
            return imageId
        }
        
        throw RoboflowError.uploadFailed(message: "No image ID returned")
    }
    
    private func annotateAsNull(
        imageId: String,
        workspace: String,
        project: String,
        apiKey: String
    ) async throws {
        // Create empty annotation (null frame) - api_key and name as query params
        var components = URLComponents(string: "https://api.roboflow.com/dataset/\(project)/annotate/\(imageId)")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "name", value: imageId)
        ]
        
        guard let annotateURL = components.url else {
            throw RoboflowError.invalidURL
        }
        
        var request = URLRequest(url: annotateURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Empty annotation file means no objects detected (null frame)
        let annotationFile: [String: Any] = [:]
        let annotation: [String: Any] = [
            "annotationFile": annotationFile
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: annotation)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Annotation failed"
            throw RoboflowError.annotationFailed(message: errorMessage)
        }
    }
}

enum RoboflowError: LocalizedError {
    case missingConfiguration
    case invalidModelId
    case imageConversionFailed
    case invalidURL
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case uploadFailed(message: String)
    case annotationFailed(message: String)
    
    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Please configure your Model ID and API Key in Settings"
        case .invalidModelId:
            return "Model ID must be in format: workspace/version"
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
