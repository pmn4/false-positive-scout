import Foundation
import CoreML
import Vision
import Compression

// "I know I can, be what I wanna be" ~Nas (probably)
// On-device Core ML model management and caching

struct ModelVersion: Codable, Identifiable {
    let id: String
    let name: String
    let created: String?
    
    var displayName: String {
        "Version \(id)"
    }
}

class ModelManager: ObservableObject {
    static let shared = ModelManager()
    
    @Published var availableModels: [ModelVersion] = []
    @Published var currentModel: MLModel?
    @Published var currentVNCoreMLModel: VNCoreMLModel?
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    
    // Track which model is currently loaded (for UI state validation)
    @Published var loadedWorkspace: String?
    @Published var loadedProject: String?
    @Published var loadedVersion: String?
    
    private let fileManager = FileManager.default
    
    private init() {
        // Auto-load cached model at startup if configured
        loadCachedModelAtStartup()
    }
    
    // MARK: - Model Discovery
    
    func listModelVersions(workspace: String, project: String) async throws -> [ModelVersion] {
        let accessToken = try await OAuthManager.shared.getAccessToken()
        
        // Extract project slug from qualified ID
        let projectSlug = project.split(separator: "/").last.map(String.init) ?? project
        
        let url = URL(string: "https://api.roboflow.com/\(workspace)/\(projectSlug)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ModelError.listFailed
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projectDict = json["project"] as? [String: Any],
           let versions = projectDict["versions"] as? [[String: Any]] {
            
            let models = versions.compactMap { versionDict -> ModelVersion? in
                // Version ID from API (just the number)
                guard let id = versionDict["id"] as? String else { return nil }
                let name = versionDict["name"] as? String ?? "Version \(id)"
                let created = versionDict["created"] as? String
                // Store just the version number as ID
                return ModelVersion(id: id, name: name, created: created)
            }
            
            DispatchQueue.main.async {
                self.availableModels = models
            }
            
            return models
        }
        
        return []
    }
    
    // MARK: - Model Download & Caching
    
    func downloadModel(workspace: String, project: String, version: String) async throws {
        await MainActor.run {
            isDownloading = true
            downloadProgress = 0.0
        }
        
        defer {
            Task { @MainActor in
                isDownloading = false
            }
        }
        
        // Extract project slug from qualified ID (ws/proj -> proj)
        let projectSlug = project.split(separator: "/").last.map(String.init) ?? project
        
        // Check if model is already cached (compiled .mlmodelc)
        let cacheURL = getCacheURL(workspace: workspace, project: projectSlug, version: version)
        if fileManager.fileExists(atPath: cacheURL.path) {
            do {
                try await loadCachedModel(from: cacheURL, workspace: workspace, project: projectSlug, version: version)
                return
            } catch {
                // Bad cache - delete and retry download
                try? fileManager.removeItem(at: cacheURL)
            }
        }
        
        // Download Core ML model from Roboflow (roboflow-swift pattern)
        let accessToken = try await OAuthManager.shared.getAccessToken()
        
        // GET /coreml/{project}/{version} endpoint
        let downloadURL = URL(string: "https://api.roboflow.com/coreml/\(projectSlug)/\(version)")!
        var request = URLRequest(url: downloadURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ModelError.exportFailed
        }
        
        // Parse response to get coreml.model URL
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let coremlDict = json["coreml"] as? [String: Any],
              let modelURLString = coremlDict["model"] as? String,
              let modelURL = URL(string: modelURLString) else {
            throw ModelError.noDownloadLink
        }
        
        // Download the .mlmodel file
        let (tempURL, _) = try await URLSession.shared.download(from: modelURL)
        
        // Compile the model (creates .mlmodelc)
        let cacheDir = getCacheDirectory()
        if !fileManager.fileExists(atPath: cacheDir.path) {
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
        
        let compiledURL = try MLModel.compileModel(at: tempURL)
        
        // Move compiled model to cache
        if fileManager.fileExists(atPath: cacheURL.path) {
            try fileManager.removeItem(at: cacheURL)
        }
        try fileManager.moveItem(at: compiledURL, to: cacheURL)
        
        // Load the compiled model
        try await loadCachedModel(from: cacheURL, workspace: workspace, project: projectSlug, version: version)
        
        await MainActor.run {
            downloadProgress = 1.0
        }
    }
    
    private func loadCachedModel(from url: URL, workspace: String, project: String, version: String) async throws {
        let mlModel = try MLModel(contentsOf: url)
        
        // Build VNCoreMLModel once for reuse per frame
        let vnModel = try VNCoreMLModel(for: mlModel)
        
        await MainActor.run {
            self.currentModel = mlModel
            self.currentVNCoreMLModel = vnModel
            // Track loaded model identity for UI validation
            self.loadedWorkspace = workspace
            self.loadedProject = project
            self.loadedVersion = version
        }
    }
    
    // MARK: - Cache Management
    
    private func getCacheDirectory() -> URL {
        let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return cacheDir.appendingPathComponent("RoboflowModels")
    }
    
    private func getCacheURL(workspace: String, project: String, version: String) -> URL {
        let cacheDir = getCacheDirectory()
        // Use project slug (last component) and .mlmodelc for compiled models
        let projectSlug = project.split(separator: "/").last.map(String.init) ?? project
        let versionNum = version.split(separator: "/").last.map(String.init) ?? version
        return cacheDir.appendingPathComponent("\(workspace)_\(projectSlug)_v\(versionNum).mlmodelc")
    }
    
    func clearCache() throws {
        let cacheDir = getCacheDirectory()
        if fileManager.fileExists(atPath: cacheDir.path) {
            try fileManager.removeItem(at: cacheDir)
        }
    }
    
    // Load cached model at app startup if configured
    private func loadCachedModelAtStartup() {
        guard let workspace = UserDefaults.standard.string(forKey: "scout_model_workspace"),
              let project = UserDefaults.standard.string(forKey: "scout_model_project"),
              let version = UserDefaults.standard.string(forKey: "scout_model_version"),
              !workspace.isEmpty, !project.isEmpty, !version.isEmpty else {
            return
        }
        
        let projectSlug = project.split(separator: "/").last.map(String.init) ?? project
        let cacheURL = getCacheURL(workspace: workspace, project: projectSlug, version: version)
        
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            return
        }
        
        Task {
            do {
                try await loadCachedModel(from: cacheURL, workspace: workspace, project: projectSlug, version: version)
            } catch {
                // Silent fail at startup - user can retry in Settings
                print("Failed to load cached model at startup: \(error)")
            }
        }
    }
    
    // MARK: - Inference
    
    func detect(image: UIImage, confidenceThreshold: Float = 0.4) async throws -> [Detection] {
        guard let vnModel = currentVNCoreMLModel else {
            throw ModelError.noModelLoaded
        }
        
        guard let pixelBuffer = image.toCVPixelBuffer() else {
            throw ModelError.imageConversionFailed
        }
        
        // Use cached VNCoreMLModel (built once, reused per frame)
        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .scaleFill
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])
        
        guard let results = request.results as? [VNRecognizedObjectObservation] else {
            return []
        }
        
        // Convert Vision results to Detection format
        let detections = results.compactMap { observation -> Detection? in
            guard observation.confidence >= confidenceThreshold else { return nil }
            
            let boundingBox = observation.boundingBox
            let imageWidth = Double(image.size.width)
            let imageHeight = Double(image.size.height)
            
            // Vision uses normalized coordinates (0-1) with origin at bottom-left
            // Convert to center x, y, width, height in pixel coordinates
            let x = boundingBox.midX * imageWidth
            let y = (1 - boundingBox.midY) * imageHeight  // Flip Y axis
            let width = boundingBox.width * imageWidth
            let height = boundingBox.height * imageHeight
            
            let className = observation.labels.first?.identifier ?? "object"
            
            return Detection(
                x: x,
                y: y,
                width: width,
                height: height,
                confidence: Double(observation.confidence),
                className: className
            )
        }
        
        return detections
    }
}

// MARK: - Errors

enum ModelError: LocalizedError {
    case listFailed
    case exportFailed
    case noDownloadLink
    case downloadFailed(String)
    case mlpackageNotFound
    case zipNotSupported
    case noModelLoaded
    case imageConversionFailed
    
    var errorDescription: String? {
        switch self {
        case .listFailed:
            return "Failed to list model versions"
        case .exportFailed:
            return "Failed to export Core ML model"
        case .noDownloadLink:
            return "No download link in export response"
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .mlpackageNotFound:
            return ".mlpackage not found in downloaded archive"
        case .zipNotSupported:
            return "ZIP model downloads not yet supported. Please use direct .mlpackage export."
        case .noModelLoaded:
            return "No model loaded. Please download a model first."
        case .imageConversionFailed:
            return "Failed to convert image for inference"
        }
    }
}

// MARK: - UIImage Extension for Core ML

extension UIImage {
    func toCVPixelBuffer() -> CVPixelBuffer? {
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(self.size.width),
            Int(self.size.height),
            kCVPixelFormatType_32ARGB,
            attrs,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        let pixelData = CVPixelBufferGetBaseAddress(buffer)
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let context = CGContext(
            data: pixelData,
            width: Int(self.size.width),
            height: Int(self.size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            return nil
        }
        
        context.translateBy(x: 0, y: self.size.height)
        context.scaleBy(x: 1.0, y: -1.0)
        
        UIGraphicsPushContext(context)
        self.draw(in: CGRect(x: 0, y: 0, width: self.size.width, height: self.size.height))
        UIGraphicsPopContext()
        
        return buffer
    }
}
