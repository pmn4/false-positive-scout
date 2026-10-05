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
        
        // Extract slugs from qualified IDs (ws/proj -> proj, ws/proj/N -> N)
        let projectSlug = project.split(separator: "/").last.map(String.init) ?? project
        let versionNum = version.split(separator: "/").last.map(String.init) ?? version
        
        // Check if model is already cached (compiled .mlmodelc)
        let cacheURL = getCacheURL(workspace: workspace, project: projectSlug, version: versionNum)
        if fileManager.fileExists(atPath: cacheURL.path) {
            do {
                try await loadCachedModel(from: cacheURL, workspace: workspace, project: projectSlug, version: versionNum)
                return
            } catch {
                // Bad cache - delete and retry download
                try? fileManager.removeItem(at: cacheURL)
            }
        }
        
        // Download Core ML model from Roboflow (roboflow-swift pattern)
        let accessToken = try await OAuthManager.shared.getAccessToken()
        
        // GET /coreml/{project}/{version} endpoint (version is numeric N)
        let downloadURL = URL(string: "https://api.roboflow.com/coreml/\(projectSlug)/\(versionNum)")!
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
        
        // Download the .mlmodel file (or .zip containing it)
        let (tempURL, _) = try await URLSession.shared.download(from: modelURL)
        
        // Detect if downloaded file is a zip
        let pathExtension = tempURL.pathExtension.lowercased()
        let isZip = pathExtension == "zip"
        
        // Check for zip magic bytes if extension is ambiguous (read only first 2 bytes)
        var isZipByContent = false
        if !isZip, let fileHandle = try? FileHandle(forReadingFrom: tempURL) {
            defer { try? fileHandle.close() }
            if let header = try? fileHandle.read(upToCount: 2), header.count == 2 {
                isZipByContent = (header == Data([0x50, 0x4B]))  // "PK" magic bytes
            }
        }
        
        if isZip || isZipByContent {
            // Core ML models packaged as .zip require unzipping
            // iOS doesn't have built-in sync unzip, and async Process isn't available
            throw ModelError.zipNotSupported
        }
        
        // URLSession temp files are often extensionless; add .mlmodel extension before compile
        let tempWithExtension = tempURL.deletingLastPathComponent()
            .appendingPathComponent(tempURL.lastPathComponent)
            .appendingPathExtension("mlmodel")
        try fileManager.moveItem(at: tempURL, to: tempWithExtension)
        
        // Compile the model (creates .mlmodelc)
        let cacheDir = getCacheDirectory()
        if !fileManager.fileExists(atPath: cacheDir.path) {
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
        
        let compiledURL = try MLModel.compileModel(at: tempWithExtension)
        
        // Move compiled model to cache
        if fileManager.fileExists(atPath: cacheURL.path) {
            try fileManager.removeItem(at: cacheURL)
        }
        try fileManager.moveItem(at: compiledURL, to: cacheURL)
        
        // Load the compiled model
        try await loadCachedModel(from: cacheURL, workspace: workspace, project: projectSlug, version: versionNum)
        
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
        
        // Strip to slugs (project may be ws/proj, version may be ws/proj/N)
        let projectSlug = project.split(separator: "/").last.map(String.init) ?? project
        let versionNum = version.split(separator: "/").last.map(String.init) ?? version
        let cacheURL = getCacheURL(workspace: workspace, project: projectSlug, version: versionNum)
        
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            return
        }
        
        Task {
            do {
                try await loadCachedModel(from: cacheURL, workspace: workspace, project: projectSlug, version: versionNum)
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
        
        // Check if results are standard Vision object detections
        guard let results = request.results as? [VNRecognizedObjectObservation] else {
            // RF-DETR and other custom models output feature maps, not VNRecognizedObjectObservation
            // They require custom post-processing of MLMultiArray outputs
            throw ModelError.unsupportedModelType
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
    case unsupportedModelType
    
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
            return "This model is packaged as a ZIP file. Scout cannot unzip on iOS. Please re-export the model from Roboflow as an uncompressed Core ML model, or use a different model version."
        case .noModelLoaded:
            return "No model loaded. Please download a model first."
        case .imageConversionFailed:
            return "Failed to convert image for inference"
        case .unsupportedModelType:
            return "This model type (likely RF-DETR) requires custom post-processing not yet implemented. Please use a YOLOv5/YOLOv8 or standard Vision-compatible Core ML model."
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
