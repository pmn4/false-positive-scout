import Foundation
import UIKit
import CoreML
import Vision
import Compression
import ZIPFoundation

// "I know I can, be what I wanna be" ~Nas (probably)
// On-device Core ML model management and caching

struct ModelVersion: Codable, Identifiable {
    let id: String
    let name: String
    let created: String?
    let modelType: String?
    let map: Double?
    let hasExports: Bool
    
    var displayName: String {
        if let type = modelType {
            return "v\(id) (\(type))"
        } else {
            return "v\(id)"
        }
    }
    
    var detailText: String? {
        var parts: [String] = []
        if let map = map {
            parts.append("mAP: \(Int(map * 100))%")
        }
        if let created = created, let date = parseDate(created) {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            parts.append(formatter.string(from: date))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
    
    var availabilityStatus: String? {
        return nil
    }
    
    private func parseDate(_ dateString: String) -> Date? {
        if let timestamp = Double(dateString) {
            return Date(timeIntervalSince1970: timestamp)
        }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: dateString)
    }
}

class ModelManager: ObservableObject {
    static let shared = ModelManager()
    
    @Published var availableModels: [ModelVersion] = []
    @Published var currentModel: MLModel?
    /// True once startup cache restore has finished (or there was nothing to restore).
    @Published var isStartupReady = false
    @Published var currentVNCoreMLModel: VNCoreMLModel?
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadStage: String = ""
    
    // Track which model is currently loaded (for UI state validation)
    @Published var loadedWorkspace: String?
    @Published var loadedProject: String?
    @Published var loadedVersion: String?
    @Published var classLabels: [String] = []
    @Published var classColors: [String: String] = [:]
    @Published var modelType: String?
    
    private enum InferenceBackend {
        case visionObjects
        case rfDetrTensors
    }
    
    private enum PreprocessingMode {
        case stretch
        case letterbox
        case centerCrop
    }
    
    private var inferenceBackend: InferenceBackend = .visionObjects
    private var preprocessingMode: PreprocessingMode = .stretch
    
    private struct ModelPreprocessingInfo: Codable {
        let resizeMode: String?
        let width: Int?
        let height: Int?
        
        var mode: PreprocessingMode {
            guard let resize = resizeMode?.lowercased() else {
                return .stretch
            }
            
            if resize.contains("stretch") || resize.contains("fill") {
                return .stretch
            } else if resize.contains("fit") || resize.contains("letterbox") {
                return .letterbox
            } else if resize.contains("crop") {
                return .centerCrop
            }
            
            return .stretch
        }
    }
    
    private let fileManager = FileManager.default
    
    private init() {
        // Auto-load cached model at startup if configured
        loadCachedModelAtStartup()
    }
    
    // MARK: - Model Discovery
    
    func listModelVersions(workspace: String, project: String) async throws -> [ModelVersion] {
        let projectSlug = project.split(separator: "/").last.map(String.init) ?? project
        
        let request = URLRequest(url: URL(string: "https://api.roboflow.com/\(workspace)/\(projectSlug)")!)
        let (data, httpResponse) = try await OAuthManager.shared.authorizedData(for: request)
        
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            throw ModelError.listFailedWithReason("HTTP \(httpResponse.statusCode): \(errorBody)")
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // GET /{workspace}/{project} returns versions at TOP level (not project.versions)
            var versionsArray: [[String: Any]]?
            if let topLevelVersions = json["versions"] as? [[String: Any]] {
                versionsArray = topLevelVersions
            } else if let projectDict = json["project"] as? [String: Any],
                      let projectVersions = projectDict["versions"] as? [[String: Any]] {
                versionsArray = projectVersions
            }
            
            if let versions = versionsArray {
                let models = versions.compactMap { versionDict -> ModelVersion? in
                    guard let idRaw = versionDict["id"] as? String else { return nil }
                    
                    let versionNumber = idRaw.split(separator: "/").last.map(String.init) ?? idRaw
                    
                    let name = versionDict["name"] as? String ?? "Version \(versionNumber)"
                    let created = (versionDict["created"] as? String) ?? (versionDict["created"] as? NSNumber).map { "\($0)" }
                    
                    let hasExports = (versionDict["exports"] != nil) || 
                                    (versionDict["model"] != nil) ||
                                    (versionDict["models"] != nil)
                    
                    let modelType: String?
                    if let modelDict = versionDict["model"] as? [String: Any],
                       let type = modelDict["type"] as? String {
                        modelType = type
                    } else if let modelsArray = versionDict["models"] as? [[String: Any]],
                              let firstModel = modelsArray.first,
                              let type = firstModel["type"] as? String {
                        modelType = type
                    } else {
                        modelType = nil
                    }
                    
                    let map: Double?
                    if let modelDict = versionDict["model"] as? [String: Any],
                       let mapValue = modelDict["map"] as? Double {
                        map = mapValue
                    } else if let mapValue = versionDict["map"] as? Double {
                        map = mapValue
                    } else {
                        map = nil
                    }
                    
                    return ModelVersion(
                        id: versionNumber,
                        name: name,
                        created: created,
                        modelType: modelType,
                        map: map,
                        hasExports: hasExports
                    )
                }
                .sorted { a, b in
                    guard let aNum = Int(a.id), let bNum = Int(b.id) else {
                        return a.id > b.id
                    }
                    return aNum > bNum
                }
                
                await MainActor.run {
                    self.availableModels = models
                }
                
                return models
            }
        }
        
        return []
    }
    
    // MARK: - Model Download & Caching
    
    func downloadModel(workspace: String, project: String, version: String) async throws {
        await MainActor.run {
            isDownloading = true
            downloadProgress = 0.0
            downloadStage = "Starting..."
        }
        
        defer {
            Task { @MainActor in
                isDownloading = false
                downloadStage = ""
            }
        }
        
        // Extract slugs from qualified IDs (ws/proj -> proj, ws/proj/N -> N)
        let projectSlug = project.split(separator: "/").last.map(String.init) ?? project
        let versionNum = version.split(separator: "/").last.map(String.init) ?? version
        
        // Check if model is already cached (compiled .mlmodelc)
        let cacheURL = getCacheURL(workspace: workspace, project: projectSlug, version: versionNum)
        if fileManager.fileExists(atPath: cacheURL.path) {
            await MainActor.run {
                downloadStage = "Loading cached model..."
            }
            do {
                try await loadCachedModel(from: cacheURL, workspace: workspace, project: projectSlug, version: versionNum)
                return
            } catch {
                // Bad cache - delete and retry download
                try? fileManager.removeItem(at: cacheURL)
            }
        }
        
        await MainActor.run {
            downloadStage = "Fetching model info..."
            downloadProgress = 0.1
        }
        
        // Download Core ML model from Roboflow (roboflow-swift pattern)
        var components = URLComponents(string: "https://api.roboflow.com/coreml/\(projectSlug)/\(versionNum)")!
        
        var queryItems: [URLQueryItem] = []
        
        #if os(iOS)
        let deviceID = await MainActor.run {
            UIDevice.current.identifierForVendor?.uuidString
        }
        if let deviceID {
            queryItems.append(URLQueryItem(name: "device", value: deviceID))
        }
        #endif
        
        queryItems.append(URLQueryItem(name: "nocache", value: "true"))
        components.queryItems = queryItems
        
        guard let downloadURL = components.url else {
            throw ModelError.exportFailed
        }
        
        let request = URLRequest(url: downloadURL)
        let (data, httpResponse) = try await OAuthManager.shared.authorizedData(for: request)
        
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            let truncatedBody = errorBody.prefix(200)
            throw ModelError.exportFailedWithReason("HTTP \(httpResponse.statusCode): \(truncatedBody)")
        }
        
        await MainActor.run {
            downloadStage = "Downloading model..."
            downloadProgress = 0.3
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelError.exportFailedWithReason("Invalid JSON response from /coreml endpoint")
        }
        
        guard let coremlDict = json["coreml"] as? [String: Any] else {
            let availableKeys = json.keys.joined(separator: ", ")
            let message = json["message"] as? String ?? json["error"] as? String
            let details = message.map { ": \($0)" } ?? ""
            throw ModelError.exportFailedWithReason("No 'coreml' key in response. Available keys: \(availableKeys)\(details)")
        }
        
        if let type = coremlDict["modelType"] as? String {
            await MainActor.run {
                self.modelType = type
            }
        }
        
        let preprocessInfo = extractPreprocessingInfo(from: json)
        
        var classNames: [String] = []
        if let coremlClasses = coremlDict["classes"] as? [String] {
            classNames = coremlClasses
            ScoutLog.decision("🔵 [ScoutDetect] /coreml endpoint classes[\(coremlClasses.count)]: \(coremlClasses.joined(separator: ", "))")
        }
        
        let (_, classColors) = try await fetchProjectMetadata(
            workspace: workspace,
            project: projectSlug,
            version: versionNum
        )
        
        guard let modelURLString = coremlDict["model"] as? String,
              let modelURL = URL(string: modelURLString) else {
            let coremlKeys = coremlDict.keys.joined(separator: ", ")
            throw ModelError.exportFailedWithReason("No model URL in coreml dict. Available keys: \(coremlKeys)")
        }
        
        // Download the .mlmodel file (or .zip containing it)
        let (tempURL, downloadResponse) = try await OAuthManager.shared.authorizedDownload(from: modelURL)
        
        await MainActor.run {
            downloadStage = "Download complete"
            downloadProgress = 0.6
        }
        
        // Check HTTP status before treating response as a model
        guard let httpResponse = downloadResponse as? HTTPURLResponse else {
            try? fileManager.removeItem(at: tempURL)
            throw ModelError.downloadFailed("Invalid download response")
        }
        
        guard httpResponse.statusCode == 200 else {
            try? fileManager.removeItem(at: tempURL)
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw ModelError.downloadFailed("Authentication failed (status \(httpResponse.statusCode))")
            } else {
                throw ModelError.downloadFailed("Download failed with status \(httpResponse.statusCode)")
            }
        }
        
        // Detect if downloaded file is a zip
        let pathExtension = tempURL.pathExtension.lowercased()
        let isZip = pathExtension == "zip"
        
        // Check for zip magic bytes if extension is ambiguous
        var isZipByContent = false
        if !isZip, let fileHandle = try? FileHandle(forReadingFrom: tempURL) {
            defer { try? fileHandle.close() }
            if let header = try? fileHandle.read(upToCount: 2), header.count == 2 {
                isZipByContent = (header == Data([0x50, 0x4B]))
            }
        }
        
        let localModelURL: URL
        var extractDirToCleanup: URL?
        
        if isZip || isZipByContent {
            let zipURL = tempURL.deletingLastPathComponent()
                .appendingPathComponent(tempURL.lastPathComponent)
                .appendingPathExtension("zip")
            try fileManager.moveItem(at: tempURL, to: zipURL)
            
            await MainActor.run {
                downloadStage = "Unpacking..."
                downloadProgress = 0.7
            }
            
            let extractedURL = try await extractModelFromZip(zipURL)
            
            if extractedURL.lastPathComponent.starts(with: UUID().uuidString.prefix(8)) {
                extractDirToCleanup = extractedURL
            }
            
            localModelURL = extractedURL
        } else {
            let tempWithExtension = tempURL.deletingLastPathComponent()
                .appendingPathComponent(tempURL.lastPathComponent)
                .appendingPathExtension("mlmodel")
            try fileManager.moveItem(at: tempURL, to: tempWithExtension)
            localModelURL = tempWithExtension
        }
        
        defer {
            if let cleanupDir = extractDirToCleanup {
                try? fileManager.removeItem(at: cleanupDir)
            } else {
                try? fileManager.removeItem(at: localModelURL)
            }
        }
        
        await MainActor.run {
            downloadStage = "Compiling for this iPhone..."
            downloadProgress = 0.8
        }
        
        // Compile the model (creates .mlmodelc) - skip if already compiled
        let cacheDir = getCacheDirectory()
        if !fileManager.fileExists(atPath: cacheDir.path) {
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
        
        let compiledURL: URL
        if localModelURL.pathExtension == "mlmodelc" {
            compiledURL = localModelURL
        } else {
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: localModelURL.path, isDirectory: &isDirectory)
            
            if isDirectory.boolValue {
                let modelFiles = try fileManager.contentsOfDirectory(at: localModelURL, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "mlmodel" }
                
                if let modelFile = modelFiles.first {
                    compiledURL = try await MLModel.compileModel(at: modelFile)
                } else if localModelURL.pathExtension == "mlpackage" {
                    compiledURL = try await MLModel.compileModel(at: localModelURL)
                } else {
                    throw ModelError.noModelInArchive("No .mlmodel found in directory")
                }
            } else {
                compiledURL = try await MLModel.compileModel(at: localModelURL)
            }
        }
        
        await MainActor.run {
            downloadStage = "Loading..."
            downloadProgress = 0.9
        }
        
        // Move compiled model to cache
        if fileManager.fileExists(atPath: cacheURL.path) {
            try fileManager.removeItem(at: cacheURL)
        }
        try fileManager.moveItem(at: compiledURL, to: cacheURL)
        
        if let preprocessData = try? JSONEncoder().encode(preprocessInfo) {
            UserDefaults.standard.set(preprocessData, forKey: "scout_model_preprocessing_\(workspace)_\(projectSlug)_\(versionNum)")
        }
        
        if !classNames.isEmpty {
            if let classData = try? JSONEncoder().encode(classNames) {
                UserDefaults.standard.set(classData, forKey: "scout_model_classes_v2_\(workspace)_\(projectSlug)_\(versionNum)")
            }
        }
        
        if !classColors.isEmpty {
            if let colorData = try? JSONEncoder().encode(classColors) {
                UserDefaults.standard.set(colorData, forKey: "scout_model_colors_\(workspace)_\(projectSlug)_\(versionNum)")
            }
        }
        
        try await loadCachedModel(from: cacheURL, workspace: workspace, project: projectSlug, version: versionNum)
        
        await MainActor.run {
            downloadStage = "Ready"
            downloadProgress = 1.0
        }
    }
    
    private func fetchCoreMLClasses(
        workspace: String,
        project: String,
        version: String
    ) async throws -> [String] {
        let request = URLRequest(url: URL(string: "https://api.roboflow.com/coreml/\(project)/\(version)")!)
        let (data, httpResponse) = try await OAuthManager.shared.authorizedData(for: request)
        
        guard httpResponse.statusCode == 200 else {
            ScoutLog.decision("🟡 [ScoutDetect] fetchCoreMLClasses failed: HTTP \(httpResponse.statusCode)")
            return []
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let coremlDict = json["coreml"] as? [String: Any],
              let classes = coremlDict["classes"] as? [String] else {
            ScoutLog.decision("🟡 [ScoutDetect] fetchCoreMLClasses: no coreml.classes in response")
            return []
        }
        
        ScoutLog.decision("🔵 [ScoutDetect] fetchCoreMLClasses: \(workspace)/\(project)/\(version) → \(classes.count) classes")
        return classes
    }
    
    private func fetchProjectMetadata(
        workspace: String,
        project: String,
        version: String
    ) async throws -> ([String], [String: String]) {
        var classNames: [String] = []
        var classColors: [String: String] = [:]
        
        let request = URLRequest(url: URL(string: "https://api.roboflow.com/\(workspace)/\(project)")!)
        let (data, httpResponse) = try await OAuthManager.shared.authorizedData(for: request)
        
        guard httpResponse.statusCode == 200 else {
            ScoutLog.decision("🟡 [ScoutDetect] fetchProjectMetadata failed: HTTP \(httpResponse.statusCode)")
            return ([], [:])
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            ScoutLog.decision("🟡 [ScoutDetect] fetchProjectMetadata: Invalid JSON")
            return ([], [:])
        }
        
        ScoutLog.decision("🔵 [ScoutDetect] fetchProjectMetadata: \(workspace)/\(project)/\(version)")
        
        if let project = json["project"] as? [String: Any] {
            if let colors = project["colors"] as? [String: String] {
                classColors = colors
            }
        }
        
        if let versions = json["versions"] as? [[String: Any]] {
            if let versionData = versions.first(where: { v in
                if let vId = v["id"] as? String {
                    return vId.split(separator: "/").last.map(String.init) == version
                }
                return false
            }) {
                if let classMap = versionData["class_map"] as? [String: Int] {
                    ScoutLog.decision("🔵 [ScoutDetect] class_map found: \(classMap)")
                    
                    let maxIndex = classMap.values.max() ?? 0
                    let minIndex = classMap.values.min() ?? 0
                    ScoutLog.decision("🔵 [ScoutDetect] Index range: \(minIndex)...\(maxIndex)")
                    
                    var denseArray = Array(repeating: "", count: maxIndex + 1)
                    for (name, index) in classMap {
                        if index >= 0 && index < denseArray.count {
                            denseArray[index] = name
                        }
                    }
                    
                    classNames = denseArray
                    ScoutLog.decision("🔵 [ScoutDetect] Dense classLabels[\(denseArray.count)]: \(denseArray.enumerated().map { "\($0):\($1.isEmpty ? "—" : $1)" }.joined(separator: ", "))")
                } else if let classes = versionData["classes"] as? [String] {
                    classNames = classes
                    ScoutLog.decision("🔵 [ScoutDetect] classes array: \(classes)")
                }
            }
        }
        
        if classNames.isEmpty, let version = json["version"] as? [String: Any] {
            if let classMap = version["class_map"] as? [String: Int] {
                let sortedClasses = classMap.sorted { $0.value < $1.value }
                classNames = sortedClasses.map { $0.key }
            } else if let classes = version["classes"] as? [String] {
                classNames = classes
            }
        }
        
        return (classNames, classColors)
    }
    
    private func extractPreprocessingInfo(from apiResponse: [String: Any]) -> ModelPreprocessingInfo {
        var resizeMode: String?
        var width: Int?
        var height: Int?
        
        if let preprocessing = apiResponse["preprocessing"] as? [String: Any] {
            if let resize = preprocessing["resize"] as? [String: Any] {
                resizeMode = resize["format"] as? String
                width = resize["width"] as? Int
                height = resize["height"] as? Int
            }
        }
        
        if let version = apiResponse["version"] as? [String: Any] {
            if let preprocessing = version["preprocessing"] as? [String: Any] {
                if let resize = preprocessing["resize"] as? [String: Any] {
                    resizeMode = resize["format"] as? String
                    width = resize["width"] as? Int
                    height = resize["height"] as? Int
                }
            }
        }
        
        if let coreml = apiResponse["coreml"] as? [String: Any] {
            if let preprocessing = coreml["preprocessing"] as? [String: Any] {
                if let resize = preprocessing["resize"] as? [String: Any] {
                    resizeMode = resize["format"] as? String
                    width = resize["width"] as? Int
                    height = resize["height"] as? Int
                }
            }
        }
        
        return ModelPreprocessingInfo(
            resizeMode: resizeMode,
            width: width,
            height: height
        )
    }
    
    private func extractModelFromZip(_ zipURL: URL) async throws -> URL {
        let extractDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)
        
        do {
            try fileManager.unzipItem(at: zipURL, to: extractDir)
            try? fileManager.removeItem(at: zipURL)
            
            let modelInfo = try findModelInDirectory(extractDir)
            
            switch modelInfo {
            case .mlpackage(let url):
                let finalURL = fileManager.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathComponent(url.lastPathComponent)
                try fileManager.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: url, to: finalURL)
                try? fileManager.removeItem(at: extractDir)
                return finalURL
                
            case .mlmodelc(let url):
                let finalURL = fileManager.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathComponent(url.lastPathComponent)
                try fileManager.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: url, to: finalURL)
                try? fileManager.removeItem(at: extractDir)
                return finalURL
                
            case .mlmodelWithWeights(_, _):
                return extractDir
                
            case .standalone(let url):
                let finalURL = fileManager.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathComponent(url.lastPathComponent)
                try fileManager.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: url, to: finalURL)
                try? fileManager.removeItem(at: extractDir)
                return finalURL
            }
        } catch {
            let fileTree = listDirectoryTree(extractDir, maxEntries: 20)
            try? fileManager.removeItem(at: extractDir)
            if let modelError = error as? ModelError {
                throw modelError
            } else {
                throw ModelError.noModelInArchive("Extraction failed. File tree: \(fileTree)")
            }
        }
    }
    
    private enum ModelLocation {
        case mlpackage(URL)
        case mlmodelc(URL)
        case mlmodelWithWeights(modelURL: URL, weightsDir: URL)
        case standalone(URL)
    }
    
    private func findModelInDirectory(_ directory: URL) throws -> ModelLocation {
        var mlpackages: [URL] = []
        var mlmodelcs: [URL] = []
        var mlmodels: [URL] = []
        var manifestDirs: [URL] = []
        
        if let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let filename = fileURL.lastPathComponent
                
                if filename.hasPrefix("__MACOSX") || filename.hasPrefix(".") {
                    continue
                }
                
                if filename == "Manifest.json" {
                    manifestDirs.append(fileURL.deletingLastPathComponent())
                }
                
                let pathExtension = fileURL.pathExtension.lowercased()
                var isDirectory: ObjCBool = false
                fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
                
                if pathExtension == "mlpackage" && isDirectory.boolValue {
                    mlpackages.append(fileURL)
                } else if pathExtension == "mlmodelc" && isDirectory.boolValue {
                    mlmodelcs.append(fileURL)
                } else if pathExtension == "mlmodel" && !isDirectory.boolValue {
                    mlmodels.append(fileURL)
                }
            }
        }
        
        if let mlpackage = mlpackages.first {
            return .mlpackage(mlpackage)
        }
        
        if let manifestDir = manifestDirs.first {
            let mlpackageURL = manifestDir.appendingPathExtension("mlpackage")
            try fileManager.moveItem(at: manifestDir, to: mlpackageURL)
            return .mlpackage(mlpackageURL)
        }
        
        if let mlmodelc = mlmodelcs.first {
            return .mlmodelc(mlmodelc)
        }
        
        if let mlmodel = mlmodels.first {
            let parentDir = mlmodel.deletingLastPathComponent()
            let weightsDir = parentDir.appendingPathComponent("weights")
            var isDirectory: ObjCBool = false
            
            if fileManager.fileExists(atPath: weightsDir.path, isDirectory: &isDirectory) && isDirectory.boolValue {
                return .mlmodelWithWeights(modelURL: mlmodel, weightsDir: weightsDir)
            } else {
                return .standalone(mlmodel)
            }
        }
        
        let fileTree = listDirectoryTree(directory, maxEntries: 20)
        throw ModelError.noModelInArchive("No model found. File tree: \(fileTree)")
    }
    
    private func listDirectoryTree(_ directory: URL, maxEntries: Int) -> String {
        var entries: [String] = []
        
        if let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
            for case let fileURL as URL in enumerator {
                if entries.count >= maxEntries {
                    entries.append("... (\(enumerator.allObjects.count - maxEntries + 1) more)")
                    break
                }
                
                let relativePath = fileURL.path.replacingOccurrences(of: directory.path + "/", with: "")
                var isDirectory: ObjCBool = false
                fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
                entries.append(relativePath + (isDirectory.boolValue ? "/" : ""))
            }
        }
        
        return entries.isEmpty ? "(empty)" : entries.joined(separator: ", ")
    }
    
    private func loadCachedModel(from url: URL, workspace: String, project: String, version: String) async throws {
        let probeConfig = MLModelConfiguration()
        #if targetEnvironment(simulator)
        probeConfig.computeUnits = .cpuOnly
        #else
        probeConfig.computeUnits = .cpuAndGPU
        #endif
        
        let probeModel = try MLModel(contentsOf: url, configuration: probeConfig)
        let backend = detectInferenceBackend(probeModel)
        
        let config = MLModelConfiguration()
        #if targetEnvironment(simulator)
        config.computeUnits = .cpuOnly
        #else
        // YoloLite needs .cpuAndGPU (Neural Engine fp16 underflow breaks decode).
        // RF-DETR matches roboflow-swift: .cpuAndNeuralEngine.
        config.computeUnits = (backend == .rfDetrTensors) ? .cpuAndNeuralEngine : .cpuAndGPU
        #endif
        
        let mlModel = (backend == .rfDetrTensors) ? try MLModel(contentsOf: url, configuration: config) : probeModel
        try await finishLoadingModel(mlModel, backend: backend, workspace: workspace, project: project, version: version)
    }
    
    private func detectInferenceBackend(_ model: MLModel) -> InferenceBackend {
        let outputNames = Set(model.modelDescription.outputDescriptionsByName.keys.map { $0.lowercased() })
        if outputNames.contains("boxes") && outputNames.contains("scores") && outputNames.contains("labels") {
            return .rfDetrTensors
        }
        return .visionObjects
    }
    
    private func finishLoadingModel(_ mlModel: MLModel, backend: InferenceBackend, workspace: String, project: String, version: String) async throws {
        let vnModel = try VNCoreMLModel(for: mlModel)
        var extractedLabels = extractClassLabels(from: mlModel)
        var labelSource = "Core ML metadata"
        
        let projectSlug = project.split(separator: "/").last.map(String.init) ?? project
        let versionNum = version.split(separator: "/").last.map(String.init) ?? version
        
        let inputDesc = mlModel.modelDescription.inputDescriptionsByName.values.first
        let imageConstraint = inputDesc?.imageConstraint
        ScoutLog.decision("🔵 [ScoutDetect] Model loaded: \(workspace)/\(projectSlug)/\(versionNum)")
        ScoutLog.decision("🔵 [ScoutDetect] ImageConstraint: \(imageConstraint?.pixelsWide ?? 0)×\(imageConstraint?.pixelsHigh ?? 0)")
        ScoutLog.decision("🔵 [ScoutDetect] Backend: \(backend == .rfDetrTensors ? "RF-DETR" : "Vision/YOLO")")
        
        if extractedLabels.isEmpty,
           let classData = UserDefaults.standard.data(forKey: "scout_model_classes_v2_\(workspace)_\(projectSlug)_\(versionNum)"),
           let classNames = try? JSONDecoder().decode([String].self, from: classData) {
            extractedLabels = classNames
            labelSource = "/coreml (cached)"
            ScoutLog.decision("🔵 [ScoutDetect] Loaded classes from cache v2: \(classNames.count) entries")
        }
        
        if extractedLabels.isEmpty {
            if let fetchedClasses = try? await fetchCoreMLClasses(
                workspace: workspace,
                project: projectSlug,
                version: versionNum
            ), !fetchedClasses.isEmpty {
                extractedLabels = fetchedClasses
                labelSource = "/coreml (refetch)"
                if let classData = try? JSONEncoder().encode(fetchedClasses) {
                    UserDefaults.standard.set(classData, forKey: "scout_model_classes_v2_\(workspace)_\(projectSlug)_\(versionNum)")
                }
                ScoutLog.decision("🔵 [ScoutDetect] Refetched classes from /coreml: \(fetchedClasses.count) entries")
            }
        }
        
        var colors: [String: String] = [:]
        if let colorData = UserDefaults.standard.data(forKey: "scout_model_colors_\(workspace)_\(projectSlug)_\(versionNum)"),
           let colorMap = try? JSONDecoder().decode([String: String].self, from: colorData) {
            colors = colorMap
        }
        
        if colors.isEmpty {
            if let (_, fetchedColors) = try? await fetchProjectMetadata(
                workspace: workspace,
                project: projectSlug,
                version: versionNum
            ) {
                if !fetchedColors.isEmpty {
                    colors = fetchedColors
                    if let colorData = try? JSONEncoder().encode(fetchedColors) {
                        UserDefaults.standard.set(colorData, forKey: "scout_model_colors_\(workspace)_\(projectSlug)_\(versionNum)")
                    }
                }
            }
        }
        
        var preprocessMode: PreprocessingMode = .stretch
        if let preprocessData = UserDefaults.standard.data(forKey: "scout_model_preprocessing_\(workspace)_\(projectSlug)_\(versionNum)"),
           let preprocessInfo = try? JSONDecoder().decode(ModelPreprocessingInfo.self, from: preprocessData) {
            preprocessMode = preprocessInfo.mode
        } else if let metadata = extractPreprocessingFromModelMetadata(mlModel) {
            preprocessMode = metadata.mode
        } else if backend == .rfDetrTensors {
            preprocessMode = .stretch
            ScoutLog.decision("⚠️ No preprocessing metadata found, defaulting to Stretch for RF-DETR")
        }
        
        let labelsForMain = extractedLabels
        let colorsForMain = colors
        let preprocessForMain = preprocessMode
        let labelSourceForMain = labelSource
        
        await MainActor.run {
            let currentWorkspace = UserDefaults.standard.string(forKey: "scout_model_workspace") ?? ""
            let currentProject = UserDefaults.standard.string(forKey: "scout_model_project") ?? ""
            let currentVersion = UserDefaults.standard.string(forKey: "scout_model_version") ?? ""
            
            let projectSlugTarget = project.split(separator: "/").last.map(String.init) ?? project
            let versionNumTarget = version.split(separator: "/").last.map(String.init) ?? version
            let currentProjectSlug = currentProject.split(separator: "/").last.map(String.init) ?? currentProject
            let currentVersionNum = currentVersion.split(separator: "/").last.map(String.init) ?? currentVersion
            
            guard currentWorkspace == workspace,
                  currentProjectSlug == projectSlugTarget,
                  currentVersionNum == versionNumTarget else {
                return
            }
            
            self.currentModel = mlModel
            self.currentVNCoreMLModel = vnModel
            self.classLabels = labelsForMain
            self.classColors = colorsForMain
            self.inferenceBackend = backend
            self.preprocessingMode = preprocessForMain
            self.loadedWorkspace = workspace
            self.loadedProject = project
            self.loadedVersion = version
            
            ScoutLog.decision("🔵 [ScoutDetect] ResizeMode: \(preprocessForMain == .stretch ? "Stretch" : preprocessForMain == .letterbox ? "Letterbox" : "CenterCrop")")
            ScoutLog.decision("🔵 [ScoutDetect] Label source: \(labelSourceForMain)")
            ScoutLog.decision("🔵 [ScoutDetect] Full index→name: [\(labelsForMain.enumerated().map { "\($0):\($1.isEmpty ? "—" : $1)" }.joined(separator: ", "))]")
            ScoutLog.decision("🔵 [ScoutDetect] Colors: \(colorsForMain.count) classes with colors")
        }
    }
    
    private func extractPreprocessingFromModelMetadata(_ model: MLModel) -> ModelPreprocessingInfo? {
        let metadata = model.modelDescription.metadata
        
        for (key, value) in metadata {
            if let stringValue = value as? String {
                if key.rawValue.lowercased().contains("preprocess") || key.rawValue.lowercased().contains("resize") {
                    return ModelPreprocessingInfo(resizeMode: stringValue, width: nil, height: nil)
                }
            }
        }
        
        return nil
    }
    
    private func extractClassLabels(from model: MLModel) -> [String] {
        let description = model.modelDescription
        
        let outputNames = Set(description.outputDescriptionsByName.keys.map { $0.lowercased() })
        let isRFDetr = outputNames.contains("boxes") && outputNames.contains("scores") && outputNames.contains("labels")
        
        if let classLabels = description.classLabels as? [String] {
            if isRFDetr {
                let hasBackground = !classLabels.isEmpty && classLabels[0].lowercased().contains("background")
                if !hasBackground {
                    ScoutLog.decision("🔵 [ScoutDetect] Ignoring Core ML classLabels (RF-DETR without background slot)")
                    return []
                }
            }
            return classLabels
        }
        
        if let metadata = description.metadata[.creatorDefinedKey] as? [String: String] {
            for key in ["classes", "names", "class_labels"] {
                if let value = metadata[key] {
                    if let parsed = parseClassLabelsFromString(value) {
                        if isRFDetr {
                            let hasBackground = !parsed.isEmpty && parsed[0].lowercased().contains("background")
                            if !hasBackground {
                                ScoutLog.decision("🔵 [ScoutDetect] Ignoring Core ML metadata classLabels (RF-DETR without background slot)")
                                return []
                            }
                        }
                        return parsed
                    }
                }
            }
        }
        
        for (metadataKey, metadataValue) in description.metadata {
            if let stringValue = metadataValue as? String {
                for key in ["classes", "names", "class_labels"] {
                    if metadataKey.rawValue.lowercased().contains(key) {
                        if let parsed = parseClassLabelsFromString(stringValue) {
                            if isRFDetr {
                                let hasBackground = !parsed.isEmpty && parsed[0].lowercased().contains("background")
                                if !hasBackground {
                                    ScoutLog.decision("🔵 [ScoutDetect] Ignoring Core ML metadata classLabels (RF-DETR without background slot)")
                                    return []
                                }
                            }
                            return parsed
                        }
                    }
                }
            }
        }
        
        if let userDefined = description.metadata[MLModelMetadataKey(rawValue: "com.apple.coreml.model.user_defined")] as? [String: String] {
            for key in ["classes", "names", "class_labels"] {
                if let value = userDefined[key] {
                    if let parsed = parseClassLabelsFromString(value) {
                        if isRFDetr {
                            let hasBackground = !parsed.isEmpty && parsed[0].lowercased().contains("background")
                            if !hasBackground {
                                ScoutLog.decision("🔵 [ScoutDetect] Ignoring Core ML metadata classLabels (RF-DETR without background slot)")
                                return []
                            }
                        }
                        return parsed
                    }
                }
            }
        }
        
        return []
    }
    
    private func parseClassLabelsFromString(_ value: String) -> [String]? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            if let data = trimmed.data(using: .utf8),
               let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
                return array
            }
        }
        
        if trimmed.hasPrefix("{") && trimmed.contains(":") {
            let pairs = trimmed
                .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
                .components(separatedBy: ",")
                .compactMap { pair -> (Int, String)? in
                    let parts = pair.components(separatedBy: ":")
                    guard parts.count == 2,
                          let index = Int(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                          let className = parts[1]
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                            .nilIfEmpty else {
                        return nil
                    }
                    return (index, className)
                }
                .sorted { $0.0 < $1.0 }
            
            if !pairs.isEmpty {
                return pairs.map { $0.1 }
            }
        }
        
        let commaSeparated = trimmed.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        if commaSeparated.count > 1 {
            return commaSeparated
        }
        
        return nil
    }
    
    // MARK: - Cache Management
    
    func isModelCached(workspace: String, project: String, version: String) -> Bool {
        let projectSlug = project.split(separator: "/").last.map(String.init) ?? project
        let versionNum = version.split(separator: "/").last.map(String.init) ?? version
        let cacheURL = getCacheURL(workspace: workspace, project: projectSlug, version: versionNum)
        return fileManager.fileExists(atPath: cacheURL.path)
    }
    
    func hasConfiguredModel() -> Bool {
        guard let workspace = UserDefaults.standard.string(forKey: "scout_model_workspace"),
              let project = UserDefaults.standard.string(forKey: "scout_model_project"),
              let version = UserDefaults.standard.string(forKey: "scout_model_version"),
              !workspace.isEmpty, !project.isEmpty, !version.isEmpty else {
            return false
        }
        
        return isModelCached(workspace: workspace, project: project, version: version)
    }
    
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
    
    func clearCachedModel(workspace: String, project: String, version: String) throws {
        let projectSlug = project.split(separator: "/").last.map(String.init) ?? project
        let versionNum = version.split(separator: "/").last.map(String.init) ?? version
        let cacheURL = getCacheURL(workspace: workspace, project: projectSlug, version: versionNum)
        
        if fileManager.fileExists(atPath: cacheURL.path) {
            try fileManager.removeItem(at: cacheURL)
        }
        
        UserDefaults.standard.removeObject(forKey: "scout_model_classes_v2_\(workspace)_\(projectSlug)_\(versionNum)")
        UserDefaults.standard.removeObject(forKey: "scout_model_colors_\(workspace)_\(projectSlug)_\(versionNum)")
        UserDefaults.standard.removeObject(forKey: "scout_model_preprocessing_\(workspace)_\(projectSlug)_\(versionNum)")
    }
    
    // Load cached model at app startup if configured
    private func loadCachedModelAtStartup() {
        guard let workspace = UserDefaults.standard.string(forKey: "scout_model_workspace"),
              let project = UserDefaults.standard.string(forKey: "scout_model_project"),
              let version = UserDefaults.standard.string(forKey: "scout_model_version"),
              !workspace.isEmpty, !project.isEmpty, !version.isEmpty else {
            markStartupReady()
            return
        }
        
        // Strip to slugs (project may be ws/proj, version may be ws/proj/N)
        let projectSlug = project.split(separator: "/").last.map(String.init) ?? project
        let versionNum = version.split(separator: "/").last.map(String.init) ?? version
        let cacheURL = getCacheURL(workspace: workspace, project: projectSlug, version: versionNum)
        
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            markStartupReady()
            return
        }
        
        Task {
            defer { markStartupReady() }
            do {
                try await loadCachedModel(from: cacheURL, workspace: workspace, project: projectSlug, version: versionNum)
            } catch {
                // Silent fail at startup - user can retry in Settings
                ScoutLog.decision("Failed to load cached model at startup: \(error)")
            }
        }
    }
    
    private func markStartupReady() {
        if Thread.isMainThread {
            self.isStartupReady = true
        } else {
            DispatchQueue.main.async {
                self.isStartupReady = true
            }
        }
    }
    
    // MARK: - Inference
    
    func detect(image: UIImage, thresholdManager: ThresholdManager = ThresholdManager.shared) async throws -> [Detection] {
        guard let mlModel = currentModel else {
            throw ModelError.noModelLoaded
        }
        
        guard let pixelBuffer = image.toCVPixelBuffer() else {
            throw ModelError.imageConversionFailed
        }
        
        let bufferWidth = Double(CVPixelBufferGetWidth(pixelBuffer))
        let bufferHeight = Double(CVPixelBufferGetHeight(pixelBuffer))
        
        ScoutLog.verbose("🔵 [ScoutDetect] Frame buffer: \(Int(bufferWidth))×\(Int(bufferHeight))")
        
        if inferenceBackend == .rfDetrTensors {
            let result = try await detectRFDetrDirect(
                mlModel: mlModel,
                pixelBuffer: pixelBuffer,
                imageWidth: bufferWidth,
                imageHeight: bufferHeight,
                thresholdManager: thresholdManager
            )
            
            if !result.isEmpty {
                ScoutLog.verbose("🔵 [ScoutDetect] After remap: \(result.count) detections")
                if let first = result.first {
                    ScoutLog.verbose("🔵 [ScoutDetect] First remapped: \(first.className) box=(\(Int(first.x)),\(Int(first.y)),\(Int(first.width))×\(Int(first.height)))")
                }
            }
            
            return result
        }
        
        guard let vnModel = currentVNCoreMLModel else {
            throw ModelError.noModelLoaded
        }
        
        let request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .scaleFill
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])
        
        guard let results = request.results, !results.isEmpty else {
            return []
        }
        
        if let objectResults = results as? [VNDetectedObjectObservation] {
            return decodeVisionObjects(
                objectResults,
                imageWidth: Double(image.size.width),
                imageHeight: Double(image.size.height),
                thresholdManager: thresholdManager
            )
        }
        
        let resultType = String(describing: type(of: results.first!))
        throw ModelError.unsupportedModelTypeWithReason("Unsupported result type: \(resultType)")
    }
    
    private func detectRFDetrDirect(
        mlModel: MLModel,
        pixelBuffer: CVPixelBuffer,
        imageWidth: Double,
        imageHeight: Double,
        thresholdManager: ThresholdManager
    ) async throws -> [Detection] {
        let inputName = mlModel.modelDescription.inputDescriptionsByName.keys.first ?? "image"
        
        guard let inputDescription = mlModel.modelDescription.inputDescriptionsByName[inputName],
              let imageConstraint = inputDescription.imageConstraint else {
            throw ModelError.unsupportedModelTypeWithReason("Model input has no image constraint")
        }
        
        let modelWidth = imageConstraint.pixelsWide
        let modelHeight = imageConstraint.pixelsHigh
        
        ScoutLog.verbose("🔵 [ScoutDetect] Resizing \(Int(imageWidth))×\(Int(imageHeight)) → \(modelWidth)×\(modelHeight) mode=\(preprocessingMode == .stretch ? "Stretch" : "Letterbox")")
        
        let (resizedBuffer, scaleInfo) = try resizePixelBufferForModel(
            pixelBuffer,
            targetWidth: modelWidth,
            targetHeight: modelHeight,
            mode: preprocessingMode,
            originalWidth: imageWidth,
            originalHeight: imageHeight
        )
        
        switch scaleInfo {
        case .stretch(let scaleX, let scaleY):
            ScoutLog.verbose("🔵 [ScoutDetect] Stretch remap: scaleX=\(String(format: "%.3f", scaleX)), scaleY=\(String(format: "%.3f", scaleY))")
        case .letterbox(let scale, let offsetX, let offsetY):
            ScoutLog.verbose("🔵 [ScoutDetect] Letterbox remap: scale=\(String(format: "%.3f", scale)), offset=(\(Int(offsetX)),\(Int(offsetY)))")
        }
        
        let input = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: resizedBuffer)])
        let output = try mlModel.prediction(from: input)
        
        let rawDetections = try decodeRFDetrOutput(
            output,
            imageWidth: Double(modelWidth),
            imageHeight: Double(modelHeight),
            thresholdManager: thresholdManager
        )
        
        let remapped = rawDetections.map { detection in
            remapDetection(detection, scaleInfo: scaleInfo)
        }
        
        return remapped
    }
    
    private func remapDetection(_ detection: Detection, scaleInfo: ScaleInfo) -> Detection {
        switch scaleInfo {
        case .stretch(let scaleX, let scaleY):
            return Detection(
                x: detection.x * scaleX,
                y: detection.y * scaleY,
                width: detection.width * scaleX,
                height: detection.height * scaleY,
                confidence: detection.confidence,
                className: detection.className
            )
        case .letterbox(let scale, let offsetX, let offsetY):
            return Detection(
                x: (detection.x - offsetX) / scale,
                y: (detection.y - offsetY) / scale,
                width: detection.width / scale,
                height: detection.height / scale,
                confidence: detection.confidence,
                className: detection.className
            )
        }
    }
    
    private enum ScaleInfo {
        case stretch(scaleX: Double, scaleY: Double)
        case letterbox(scale: Double, offsetX: Double, offsetY: Double)
    }
    
    private func resizePixelBufferForModel(
        _ pixelBuffer: CVPixelBuffer,
        targetWidth: Int,
        targetHeight: Int,
        mode: PreprocessingMode,
        originalWidth: Double,
        originalHeight: Double
    ) throws -> (CVPixelBuffer, ScaleInfo) {
        switch mode {
        case .stretch:
            let buffer = try resizePixelBufferStretch(pixelBuffer, targetWidth: targetWidth, targetHeight: targetHeight)
            let scaleX = originalWidth / Double(targetWidth)
            let scaleY = originalHeight / Double(targetHeight)
            return (buffer, .stretch(scaleX: scaleX, scaleY: scaleY))
            
        case .letterbox:
            let (buffer, scale, offsetX, offsetY) = try resizePixelBufferLetterbox(
                pixelBuffer,
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                originalWidth: originalWidth,
                originalHeight: originalHeight
            )
            return (buffer, .letterbox(scale: scale, offsetX: offsetX, offsetY: offsetY))
            
        case .centerCrop:
            let buffer = try resizePixelBufferStretch(pixelBuffer, targetWidth: targetWidth, targetHeight: targetHeight)
            let scaleX = originalWidth / Double(targetWidth)
            let scaleY = originalHeight / Double(targetHeight)
            return (buffer, .stretch(scaleX: scaleX, scaleY: scaleY))
        }
    }
    
    private func resizePixelBufferStretch(
        _ pixelBuffer: CVPixelBuffer,
        targetWidth: Int,
        targetHeight: Int
    ) throws -> CVPixelBuffer {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        
        if sourceWidth == targetWidth && sourceHeight == targetHeight {
            return pixelBuffer
        }
        
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary
        
        var outputPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            targetWidth,
            targetHeight,
            kCVPixelFormatType_32BGRA,
            attrs,
            &outputPixelBuffer
        )
        
        guard status == kCVReturnSuccess, let outputBuffer = outputPixelBuffer else {
            throw ModelError.imageConversionFailed
        }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outputBuffer, [])
        
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(outputBuffer, [])
        }
        
        guard let sourceData = CVPixelBufferGetBaseAddress(pixelBuffer),
              let destData = CVPixelBufferGetBaseAddress(outputBuffer) else {
            throw ModelError.imageConversionFailed
        }
        
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let destBytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let sourceContext = CGContext(
            data: sourceData,
            width: sourceWidth,
            height: sourceHeight,
            bitsPerComponent: 8,
            bytesPerRow: sourceBytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ),
        let sourceCGImage = sourceContext.makeImage() else {
            throw ModelError.imageConversionFailed
        }
        
        guard let destContext = CGContext(
            data: destData,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: destBytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw ModelError.imageConversionFailed
        }
        
        destContext.draw(
            sourceCGImage,
            in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        )
        
        return outputBuffer
    }
    
    private func resizePixelBufferLetterbox(
        _ pixelBuffer: CVPixelBuffer,
        targetWidth: Int,
        targetHeight: Int,
        originalWidth: Double,
        originalHeight: Double
    ) throws -> (CVPixelBuffer, Double, Double, Double) {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ] as CFDictionary
        
        var outputPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            targetWidth,
            targetHeight,
            kCVPixelFormatType_32BGRA,
            attrs,
            &outputPixelBuffer
        )
        
        guard status == kCVReturnSuccess, let outputBuffer = outputPixelBuffer else {
            throw ModelError.imageConversionFailed
        }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outputBuffer, [])
        
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(outputBuffer, [])
        }
        
        guard let sourceData = CVPixelBufferGetBaseAddress(pixelBuffer),
              let destData = CVPixelBufferGetBaseAddress(outputBuffer) else {
            throw ModelError.imageConversionFailed
        }
        
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let destBytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        guard let sourceContext = CGContext(
            data: sourceData,
            width: sourceWidth,
            height: sourceHeight,
            bitsPerComponent: 8,
            bytesPerRow: sourceBytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ),
        let sourceCGImage = sourceContext.makeImage() else {
            throw ModelError.imageConversionFailed
        }
        
        guard let destContext = CGContext(
            data: destData,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: destBytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw ModelError.imageConversionFailed
        }
        
        let scaleX = CGFloat(targetWidth) / CGFloat(sourceWidth)
        let scaleY = CGFloat(targetHeight) / CGFloat(sourceHeight)
        let scale = min(scaleX, scaleY)
        
        let scaledWidth = CGFloat(sourceWidth) * scale
        let scaledHeight = CGFloat(sourceHeight) * scale
        let offsetX = (CGFloat(targetWidth) - scaledWidth) / 2.0
        let offsetY = (CGFloat(targetHeight) - scaledHeight) / 2.0
        
        destContext.setFillColor(UIColor.black.cgColor)
        destContext.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        
        destContext.draw(
            sourceCGImage,
            in: CGRect(x: offsetX, y: offsetY, width: scaledWidth, height: scaledHeight)
        )
        
        let remapScale = originalWidth / Double(targetWidth) * Double(scale)
        
        return (outputBuffer, remapScale, Double(offsetX), Double(offsetY))
    }
    
    private func decodeRFDetrOutput(
        _ output: MLFeatureProvider,
        imageWidth: Double,
        imageHeight: Double,
        thresholdManager: ThresholdManager
    ) throws -> [Detection] {
        guard let boxesFeature = output.featureValue(for: "boxes")?.multiArrayValue,
              let scoresFeature = output.featureValue(for: "scores")?.multiArrayValue,
              let labelsFeature = output.featureValue(for: "labels")?.multiArrayValue else {
            throw ModelError.unsupportedModelTypeWithReason("RF-DETR outputs (boxes/scores/labels) not found in model output")
        }
        
        let batched = boxesFeature.shape.count == 3
        let numDetections: Int
        if batched {
            numDetections = boxesFeature.shape[1].intValue
        } else if boxesFeature.shape.count == 2 {
            numDetections = boxesFeature.shape[0].intValue
        } else {
            throw ModelError.unsupportedModelTypeWithReason("Unexpected boxes shape: \(boxesFeature.shape)")
        }
        
        ScoutLog.verbose("🔵 [ScoutDetect] decodeRFDetrOutput: \(numDetections) raw detections from model")
        
        var detections: [Detection] = []
        detections.reserveCapacity(min(numDetections, 64))
        
        var topDetections: [(idx: Int, score: Float, cx: Float, cy: Float)] = []
        
        for i in 0..<numDetections {
            let score: Float
            let labelIdx: Int
            let cx: Float
            let cy: Float
            let w: Float
            let h: Float
            
            if batched {
                score = scoresFeature[[0, NSNumber(value: i)] as [NSNumber]].floatValue
                labelIdx = labelsFeature[[0, NSNumber(value: i)] as [NSNumber]].intValue
                cx = boxesFeature[[0, NSNumber(value: i), 0] as [NSNumber]].floatValue
                cy = boxesFeature[[0, NSNumber(value: i), 1] as [NSNumber]].floatValue
                w = abs(boxesFeature[[0, NSNumber(value: i), 2] as [NSNumber]].floatValue)
                h = abs(boxesFeature[[0, NSNumber(value: i), 3] as [NSNumber]].floatValue)
            } else {
                let scoreIdx: [NSNumber] = (scoresFeature.shape.count == 2)
                    ? [0, NSNumber(value: i)]
                    : [NSNumber(value: i)]
                let labelIndex: [NSNumber] = (labelsFeature.shape.count == 2)
                    ? [0, NSNumber(value: i)]
                    : [NSNumber(value: i)]
                score = scoresFeature[scoreIdx].floatValue
                labelIdx = labelsFeature[labelIndex].intValue
                cx = boxesFeature[[NSNumber(value: i), 0] as [NSNumber]].floatValue
                cy = boxesFeature[[NSNumber(value: i), 1] as [NSNumber]].floatValue
                w = abs(boxesFeature[[NSNumber(value: i), 2] as [NSNumber]].floatValue)
                h = abs(boxesFeature[[NSNumber(value: i), 3] as [NSNumber]].floatValue)
            }
            
            if topDetections.count < 3 {
                topDetections.append((labelIdx, score, cx, cy))
            }
            
            let className: String
            let mappingNote: String
            if labelIdx >= 0 && labelIdx < classLabels.count {
                let name = classLabels[labelIdx]
                if name.isEmpty {
                    className = "unknown"
                    mappingNote = "empty@\(labelIdx)"
                } else if name.lowercased().starts(with: "background_class") {
                    if detections.count < 3 {
                        ScoutLog.verbose("🔵 [ScoutDetect] Skipping background detection: idx=\(labelIdx) name=\"\(name)\"")
                    }
                    continue
                } else {
                    className = name
                    mappingNote = "idx\(labelIdx)"
                }
            } else {
                className = "unknown"
                mappingNote = labelIdx < 0 ? "negative(\(labelIdx))" : "OOB(\(labelIdx)>=\(classLabels.count))"
            }
            
            let effectiveThreshold = Float(thresholdManager.effectiveThreshold(for: className))
            guard score > 0, score >= effectiveThreshold else { continue }
            guard w > 0, h > 0 else { continue }
            
            let centerX = Double(cx) * imageWidth
            let centerY = Double(cy) * imageHeight
            let width = Double(w) * imageWidth
            let height = Double(h) * imageHeight
            
            if detections.count < 3 {
                ScoutLog.verbose("🔵 [ScoutDetect] Det \(detections.count): labelIdx=\(labelIdx) → \"\(className)\" [\(mappingNote)] score=\(Int(score*100))% box=(\(Int(centerX)),\(Int(centerY)),\(Int(width))×\(Int(height)))")
            }
            
            detections.append(Detection(
                x: centerX,
                y: centerY,
                width: width,
                height: height,
                confidence: Double(score),
                className: className
            ))
        }
        
        if !topDetections.isEmpty {
            ScoutLog.verbose("🔵 [ScoutDetect] Top raw: \(topDetections.map { "idx\($0.idx):\(Int($0.score*100))%" }.joined(separator: ", "))")
        }
        ScoutLog.verbose("🔵 [ScoutDetect] After threshold: \(detections.count) detections")
        
        return detections
    }
    
    private func decodeVisionObjects(
        _ observations: [VNDetectedObjectObservation],
        imageWidth: Double,
        imageHeight: Double,
        thresholdManager: ThresholdManager
    ) -> [Detection] {
        observations.compactMap { observation -> Detection? in
            var score = Double(observation.confidence)
            var className = "object"
            
            if let recognized = observation as? VNRecognizedObjectObservation,
               let topLabel = recognized.labels.first {
                className = topLabel.identifier
                score = min(Double(observation.confidence) * Double(topLabel.confidence), 1.0)
            }
            
            let effectiveThreshold = Double(thresholdManager.effectiveThreshold(for: className))
            guard score > 0, score >= effectiveThreshold else { return nil }
            
            let boundingBox = observation.boundingBox
            return Detection(
                x: boundingBox.midX * imageWidth,
                y: (1 - boundingBox.midY) * imageHeight,
                width: boundingBox.width * imageWidth,
                height: boundingBox.height * imageHeight,
                confidence: score,
                className: className
            )
        }
    }
    
    /// RF-DETR Core ML outputs boxes/scores/labels MultiArrays (roboflow-swift RFDetrObjectDetectionModel).
    private func decodeRFDetrTensors(
        _ observations: [VNCoreMLFeatureValueObservation],
        imageWidth: Double,
        imageHeight: Double,
        thresholdManager: ThresholdManager
    ) throws -> [Detection] {
        var boxesArray: MLMultiArray?
        var scoresArray: MLMultiArray?
        var labelsArray: MLMultiArray?
        
        for observation in observations {
            switch observation.featureName.lowercased() {
            case "boxes":
                boxesArray = observation.featureValue.multiArrayValue
            case "scores":
                scoresArray = observation.featureValue.multiArrayValue
            case "labels":
                labelsArray = observation.featureValue.multiArrayValue
            default:
                break
            }
        }
        
        guard let boxes = boxesArray, let scores = scoresArray, let labels = labelsArray else {
            let found = observations.map(\.featureName).joined(separator: ", ")
            throw ModelError.unsupportedModelTypeWithReason("RF-DETR tensors incomplete. Found: \(found)")
        }
        
        // Prefer SDK layout: scores/labels [1, N], boxes [1, N, 4]
        let batched = boxes.shape.count == 3
        let numDetections: Int
        if batched {
            numDetections = boxes.shape[1].intValue
        } else if boxes.shape.count == 2 {
            numDetections = boxes.shape[0].intValue
        } else {
            throw ModelError.unsupportedModelTypeWithReason("Unexpected boxes shape: \(boxes.shape)")
        }
        
        var detections: [Detection] = []
        detections.reserveCapacity(min(numDetections, 64))
        
        for i in 0..<numDetections {
            let score: Float
            let labelIdx: Int
            let cx: Float
            let cy: Float
            let w: Float
            let h: Float
            
            if batched {
                score = scores[[0, NSNumber(value: i)] as [NSNumber]].floatValue
                labelIdx = labels[[0, NSNumber(value: i)] as [NSNumber]].intValue
                cx = boxes[[0, NSNumber(value: i), 0] as [NSNumber]].floatValue
                cy = boxes[[0, NSNumber(value: i), 1] as [NSNumber]].floatValue
                w = abs(boxes[[0, NSNumber(value: i), 2] as [NSNumber]].floatValue)
                h = abs(boxes[[0, NSNumber(value: i), 3] as [NSNumber]].floatValue)
            } else {
                let scoreIdx: [NSNumber] = (scores.shape.count == 2)
                    ? [0, NSNumber(value: i)]
                    : [NSNumber(value: i)]
                let labelIndex: [NSNumber] = (labels.shape.count == 2)
                    ? [0, NSNumber(value: i)]
                    : [NSNumber(value: i)]
                score = scores[scoreIdx].floatValue
                labelIdx = labels[labelIndex].intValue
                cx = boxes[[NSNumber(value: i), 0] as [NSNumber]].floatValue
                cy = boxes[[NSNumber(value: i), 1] as [NSNumber]].floatValue
                w = abs(boxes[[NSNumber(value: i), 2] as [NSNumber]].floatValue)
                h = abs(boxes[[NSNumber(value: i), 3] as [NSNumber]].floatValue)
            }
            
            let className: String
            if labelIdx >= 0 && labelIdx < classLabels.count {
                className = classLabels[labelIdx]
            } else {
                className = "unknown"
            }
            
            let effectiveThreshold = Float(thresholdManager.effectiveThreshold(for: className))
            guard score > 0, score >= effectiveThreshold else { continue }
            guard w > 0, h > 0 else { continue }
            
            // Match roboflow-swift: normalized center coords → pixel centers (no Vision Y flip).
            let centerX = Double(cx) * imageWidth
            let centerY = Double(cy) * imageHeight
            let width = Double(w) * imageWidth
            let height = Double(h) * imageHeight
            
            detections.append(Detection(
                x: centerX,
                y: centerY,
                width: width,
                height: height,
                confidence: Double(score),
                className: className
            ))
        }
        
        return detections
    }
}

// MARK: - Errors

enum ModelError: LocalizedError {
    case listFailed
    case listFailedWithReason(String)
    case exportFailed
    case exportFailedWithReason(String)
    case noDownloadLink
    case downloadFailed(String)
    case mlpackageNotFound
    case noModelInArchive(String)
    case noModelLoaded
    case imageConversionFailed
    case unsupportedModelType
    case unsupportedModelTypeWithReason(String)
    case authenticationRequired
    
    var errorDescription: String? {
        switch self {
        case .listFailed:
            return "Failed to list model versions"
        case .listFailedWithReason(let reason):
            return "Failed to list model versions: \(reason)"
        case .exportFailed:
            return "Failed to export Core ML model"
        case .exportFailedWithReason(let reason):
            return "Failed to export Core ML model: \(reason)"
        case .noDownloadLink:
            return "No download link in export response"
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .mlpackageNotFound:
            return ".mlpackage not found in downloaded archive"
        case .noModelInArchive(let contents):
            return "No Core ML model found in archive. \(contents)"
        case .noModelLoaded:
            return "No model loaded. Please download a model first."
        case .imageConversionFailed:
            return "Failed to convert image for inference"
        case .unsupportedModelType:
            return "This model type outputs feature maps requiring custom post-processing that is not yet implemented. Please use a different model architecture (e.g., YOLOv5, YOLOv8, or standard Vision-compatible detector)."
        case .unsupportedModelTypeWithReason(let reason):
            return reason
        case .authenticationRequired:
            return "Please log in with Roboflow in Settings"
        }
    }
}

// MARK: - UIImage Extension for Core ML

extension UIImage {
    func toCVPixelBuffer() -> CVPixelBuffer? {
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
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

extension String {
    var nilIfEmpty: String? {
        return isEmpty ? nil : self
    }
}
