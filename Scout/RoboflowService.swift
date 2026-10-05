import Foundation
import UIKit

// "I never sleep, 'cause sleep is the cousin of death" - Nas (probably)
// Service for calling Roboflow inference API

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
}

enum RoboflowError: LocalizedError {
    case missingConfiguration
    case invalidModelId
    case imageConversionFailed
    case invalidURL
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    
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
        }
    }
}
