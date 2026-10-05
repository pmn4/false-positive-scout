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
    var uploadedImageId: String?
    
    init(id: UUID = UUID(), timestamp: Date = Date(), detections: [Detection], imageData: Data?, kept: Bool = true, uploadedImageId: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.detections = detections
        self.imageData = imageData
        self.kept = kept
        self.uploadedImageId = uploadedImageId
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
        return frames.filter { $0.kept }
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
                uploadedImageId: frame.uploadedImageId
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
                uploadedImageId: frame.uploadedImageId
            )
        }
    }
}
