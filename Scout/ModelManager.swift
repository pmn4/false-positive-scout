import Foundation
import CoreML
import Vision

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
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    
    private let fileManager = FileManager.default
    
    private init() {}
    
    // MARK: - Model Discovery
    
    func listModelVersions(workspace: String, project: String) async throws -> [ModelVersion] {
        let accessToken = try await OAuthManager.shared.getAccessToken()
        
        let url = URL(string: "https://api.roboflow.com/\(workspace)/\(project)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ModelError.listFailed
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let project = json["project"] as? [String: Any],
           let versions = project["versions"] as? [[String: Any]] {
            
            let models = versions.compactMap { versionDict -> ModelVersion? in
                guard let id = versionDict["id"] as? String else { return nil }
                let name = versionDict["name"] as? String ?? "Version \(id)"
                let created = versionDict["created"] as? String
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
        
        // Check if model is already cached
        let cacheURL = getCacheURL(workspace: workspace, project: project, version: version)
        if fileManager.fileExists(atPath: cacheURL.path) {
            try await loadCachedModel(from: cacheURL)
            await MainActor.run {
                isDownloading = false
            }
            return
        }
        
        // Download Core ML model from Roboflow
        let accessToken = try await OAuthManager.shared.getAccessToken()
        
        // Request coreml export
        let exportURL = URL(string: "https://api.roboflow.com/\(workspace)/\(project)/\(version)/coreml")!
        var exportRequest = URLRequest(url: exportURL)
        exportRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        let (exportData, exportResponse) = try await URLSession.shared.data(for: exportRequest)
        
        guard let httpResponse = exportResponse as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            await MainActor.run {
                isDownloading = false
            }
            throw ModelError.exportFailed
        }
        
        // Parse export response to get download link
        guard let exportJSON = try? JSONSerialization.jsonObject(with: exportData) as? [String: Any],
              let exportInfo = exportJSON["export"] as? [String: Any],
              let downloadLink = exportInfo["link"] as? String,
              let downloadURL = URL(string: downloadLink) else {
            await MainActor.run {
                isDownloading = false
            }
            throw ModelError.noDownloadLink
        }
        
        // Download the .mlpackage (or zip containing it)
        let downloadTask = URLSession.shared.downloadTask(with: downloadURL) { [weak self] tempURL, response, error in
            guard let self = self else { return }
            
            if let error = error {
                Task { @MainActor in
                    self.isDownloading = false
                }
                print("Download error: \(error)")
                return
            }
            
            guard let tempURL = tempURL else {
                Task { @MainActor in
                    self.isDownloading = false
                }
                return
            }
            
            Task {
                do {
                    // Move to cache directory
                    let cacheDir = self.getCacheDirectory()
                    if !self.fileManager.fileExists(atPath: cacheDir.path) {
                        try self.fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                    }
                    
                    // Check if downloaded file is a zip or .mlpackage
                    if downloadLink.hasSuffix(".zip") {
                        // Unzip and find .mlpackage
                        try await self.unzipAndCacheModel(from: tempURL, to: cacheURL)
                    } else {
                        // Direct .mlpackage, just move it
                        try self.fileManager.moveItem(at: tempURL, to: cacheURL)
                    }
                    
                    // Load the cached model
                    try await self.loadCachedModel(from: cacheURL)
                    
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadProgress = 1.0
                    }
                } catch {
                    await MainActor.run {
                        self.isDownloading = false
                    }
                    print("Cache error: \(error)")
                }
            }
        }
        
        downloadTask.resume()
    }
    
    private func unzipAndCacheModel(from zipURL: URL, to destinationURL: URL) async throws {
        // Create a temporary directory for unzipping
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        // Unzip using NSFileCoordinator or shell (simplified approach)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", zipURL.path, "-d", tempDir.path]
        try process.run()
        process.waitUntilExit()
        
        // Find .mlpackage in unzipped contents
        let contents = try fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        guard let mlpackage = contents.first(where: { $0.pathExtension == "mlpackage" || $0.lastPathComponent.hasSuffix(".mlpackage") }) else {
            throw ModelError.mlpackageNotFound
        }
        
        // Move to cache
        try fileManager.moveItem(at: mlpackage, to: destinationURL)
        
        // Clean up temp directory
        try? fileManager.removeItem(at: tempDir)
    }
    
    private func loadCachedModel(from url: URL) async throws {
        let mlModel = try MLModel(contentsOf: url)
        
        await MainActor.run {
            self.currentModel = mlModel
        }
    }
    
    // MARK: - Cache Management
    
    private func getCacheDirectory() -> URL {
        let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return cacheDir.appendingPathComponent("RoboflowModels")
    }
    
    private func getCacheURL(workspace: String, project: String, version: String) -> URL {
        let cacheDir = getCacheDirectory()
        return cacheDir.appendingPathComponent("\(workspace)_\(project)_v\(version).mlpackage")
    }
    
    func clearCache() throws {
        let cacheDir = getCacheDirectory()
        if fileManager.fileExists(atPath: cacheDir.path) {
            try fileManager.removeItem(at: cacheDir)
        }
    }
    
    // MARK: - Inference
    
    func detect(image: UIImage, confidenceThreshold: Float = 0.4) async throws -> [Detection] {
        guard let model = currentModel else {
            throw ModelError.noModelLoaded
        }
        
        guard let pixelBuffer = image.toCVPixelBuffer() else {
            throw ModelError.imageConversionFailed
        }
        
        // Use Vision framework for inference
        let request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
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
