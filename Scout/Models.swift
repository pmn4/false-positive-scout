import Foundation
import UIKit

// "Life's a bitch, then you die" - Nas (probably)
// Core data models for Scout

struct Detection: Codable, Identifiable {
    let id = UUID()
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let confidence: Double
    let className: String
    
    enum CodingKeys: String, CodingKey {
        case x, y, width, height, confidence
        case className = "class"
    }
}

struct CapturedFrame: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let detections: [Detection]
    var imageData: Data?
    var kept: Bool
    var reviewed: Bool
    var uploadedImageId: String?
    var imageWidth: Int?
    var imageHeight: Int?
    
    init(id: UUID = UUID(), timestamp: Date = Date(), detections: [Detection], imageData: Data?, kept: Bool = true, reviewed: Bool = false, uploadedImageId: String? = nil, imageWidth: Int? = nil, imageHeight: Int? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.detections = detections
        self.imageData = imageData
        self.kept = kept
        self.reviewed = reviewed
        self.uploadedImageId = uploadedImageId
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        detections = try container.decode([Detection].self, forKey: .detections)
        imageData = try container.decodeIfPresent(Data.self, forKey: .imageData)
        kept = try container.decode(Bool.self, forKey: .kept)
        reviewed = try container.decodeIfPresent(Bool.self, forKey: .reviewed) ?? false
        uploadedImageId = try container.decodeIfPresent(String.self, forKey: .uploadedImageId)
        imageWidth = try container.decodeIfPresent(Int.self, forKey: .imageWidth)
        imageHeight = try container.decodeIfPresent(Int.self, forKey: .imageHeight)
    }
    
    var isLegacy: Bool {
        imageWidth == nil || imageHeight == nil
    }
    
    enum CodingKeys: String, CodingKey {
        case id, timestamp, detections, imageData, kept, reviewed, uploadedImageId, imageWidth, imageHeight
    }
}

class FrameStorage: ObservableObject {
    @Published var frames: [CapturedFrame] = []
    
    private let storageKey = "scout_captured_frames"
    
    init() {
        loadFrames()
    }
    
    func addFrame(_ frame: CapturedFrame) {
        frames.append(frame)
        saveFrames()
    }
    
    func deleteFrame(_ frame: CapturedFrame) {
        frames.removeAll { $0.id == frame.id }
        
        // Delete image file from documents
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let imagePath = documentsPath.appendingPathComponent("\(frame.id.uuidString).jpg")
        try? FileManager.default.removeItem(at: imagePath)
        
        saveFrames()
    }
    
    func restoreFrame(_ frame: CapturedFrame, at index: Int) {
        let insertIndex = min(index, frames.count)
        frames.insert(frame, at: insertIndex)
        saveFrames()
    }
    
    func toggleKeep(_ frame: CapturedFrame) {
        if let index = frames.firstIndex(where: { $0.id == frame.id }) {
            frames[index].kept.toggle()
            saveFrames()
        }
    }
    
    func markUploaded(_ frame: CapturedFrame, imageId: String) {
        if let index = frames.firstIndex(where: { $0.id == frame.id }) {
            frames[index].uploadedImageId = imageId
            saveFrames()
        }
    }
    
    func clearAll() {
        // Delete all image files from documents
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for frame in frames {
            let imagePath = documentsPath.appendingPathComponent("\(frame.id.uuidString).jpg")
            try? FileManager.default.removeItem(at: imagePath)
        }
        
        frames.removeAll()
        saveFrames()
    }
    
    func exportKeptFrames() -> [CapturedFrame] {
        return frames.filter { $0.reviewed && $0.kept }
    }
    
    func markReviewed(_ frame: CapturedFrame, kept: Bool) {
        if let index = frames.firstIndex(where: { $0.id == frame.id }) {
            frames[index].reviewed = true
            frames[index].kept = kept
            saveFrames()
        }
    }
    
    func undoReview(_ frame: CapturedFrame, previousKept: Bool) {
        if let index = frames.firstIndex(where: { $0.id == frame.id }) {
            frames[index].reviewed = false
            frames[index].kept = previousKept
            saveFrames()
        }
    }
    
    private func saveFrames() {
        // Store metadata without image data to avoid UserDefaults size limits
        let lightFrames = frames.map { frame in
            CapturedFrame(
                id: frame.id,
                timestamp: frame.timestamp,
                detections: frame.detections,
                imageData: nil,
                kept: frame.kept,
                reviewed: frame.reviewed,
                uploadedImageId: frame.uploadedImageId,
                imageWidth: frame.imageWidth,
                imageHeight: frame.imageHeight
            )
        }
        
        if let encoded = try? JSONEncoder().encode(lightFrames) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
        
        // Save images to documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for frame in frames {
            if let imageData = frame.imageData {
                let imagePath = documentsPath.appendingPathComponent("\(frame.id.uuidString).jpg")
                try? imageData.write(to: imagePath)
            }
        }
    }
    
    private func loadFrames() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([CapturedFrame].self, from: data) else {
            return
        }
        
        // Load image data from documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        frames = decoded.map { frame in
            let imagePath = documentsPath.appendingPathComponent("\(frame.id.uuidString).jpg")
            let imageData = try? Data(contentsOf: imagePath)
            return CapturedFrame(
                id: frame.id,
                timestamp: frame.timestamp,
                detections: frame.detections,
                imageData: imageData,
                kept: frame.kept,
                reviewed: frame.reviewed,
                uploadedImageId: frame.uploadedImageId,
                imageWidth: frame.imageWidth,
                imageHeight: frame.imageHeight
            )
        }
    }
}
