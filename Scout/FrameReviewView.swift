import SwiftUI

// "The bridge is over, the bridge is over" - Nas (probably)
// Fast swipe-through review interface for captured frames

// "Rewind like a VHS, back to the essence" ~Nas (probably)
// Undo support for review actions
struct ReviewAction {
    enum ActionType {
        case delete(frame: CapturedFrame, index: Int)
        case toggleKeep(frameId: UUID, previousState: Bool)
    }
    
    let type: ActionType
    let timestamp: Date
}

struct FrameReviewView: View {
    @EnvironmentObject var frameStorage: FrameStorage
    @State private var currentIndex = 0
    @State private var offset: CGFloat = 0
    @State private var showingDeleteAlert = false
    @State private var showingExportSheet = false
    @State private var undoStack: [ReviewAction] = []
    
    var body: some View {
        NavigationView {
            ZStack {
                if frameStorage.frames.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 80))
                            .foregroundColor(.gray)
                        
                        Text("No frames captured yet")
                            .font(.title2)
                            .foregroundColor(.gray)
                        
                        Text("Point the camera at scenes where nothing should be detected")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else {
                    VStack {
                        Text("Frame \(currentIndex + 1) of \(frameStorage.frames.count)")
                            .font(.headline)
                            .padding(.top)
                        
                        GeometryReader { geometry in
                            ZStack {
                                ForEach(Array(frameStorage.frames.enumerated()), id: \.element.id) { index, frame in
                                    if abs(index - currentIndex) <= 1 {
                                        FrameCard(
                                            frame: frame,
                                            geometry: geometry,
                                            offset: offset,
                                            index: index,
                                            currentIndex: currentIndex,
                                            onDelete: {
                                                deleteFrame(frame)
                                            },
                                            onKeep: {
                                                toggleKeep(frame)
                                            }
                                        )
                                    }
                                }
                            }
                            .gesture(
                                DragGesture()
                                    .onChanged { gesture in
                                        offset = gesture.translation.width
                                    }
                                    .onEnded { gesture in
                                        let threshold: CGFloat = 100
                                        
                                        if gesture.translation.width < -threshold && currentIndex < frameStorage.frames.count - 1 {
                                            withAnimation {
                                                currentIndex += 1
                                                offset = 0
                                            }
                                        } else if gesture.translation.width > threshold && currentIndex > 0 {
                                            withAnimation {
                                                currentIndex -= 1
                                                offset = 0
                                            }
                                        } else {
                                            withAnimation {
                                                offset = 0
                                            }
                                        }
                                    }
                            )
                        }
                        
                        if currentIndex < frameStorage.frames.count {
                            let frame = frameStorage.frames[currentIndex]
                            
                            VStack(spacing: 12) {
                                Text("\(frame.detections.count) detection\(frame.detections.count != 1 ? "s" : "")")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                Text(frame.timestamp, style: .time)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                HStack(spacing: 20) {
                                    Button(action: {
                                        deleteFrame(frame)
                                    }) {
                                        Label("Delete", systemImage: "trash")
                                            .foregroundColor(.white)
                                            .padding()
                                            .frame(maxWidth: .infinity)
                                            .background(Color.red)
                                            .cornerRadius(12)
                                    }
                                    
                                    Button(action: {
                                        toggleKeep(frame)
                                    }) {
                                        Label(
                                            frame.kept ? "Kept" : "Discarded",
                                            systemImage: frame.kept ? "checkmark.circle.fill" : "xmark.circle"
                                        )
                                        .foregroundColor(.white)
                                        .padding()
                                        .frame(maxWidth: .infinity)
                                        .background(frame.kept ? Color.green : Color.orange)
                                        .cornerRadius(12)
                                    }
                                }
                                .padding(.horizontal)
                            }
                            .padding(.bottom, 20)
                        }
                    }
                }
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        performUndo()
                    }) {
                        Image(systemName: "arrow.uturn.backward.circle")
                            .font(.title3)
                    }
                    .disabled(undoStack.isEmpty)
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: {
                            showingExportSheet = true
                        }) {
                            Label("Upload & Nullify", systemImage: "square.and.arrow.up")
                        }
                        .disabled(frameStorage.exportKeptFrames().isEmpty)
                        
                        Button(role: .destructive, action: {
                            showingDeleteAlert = true
                        }) {
                            Label("Clear All", systemImage: "trash")
                        }
                        .disabled(frameStorage.frames.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .alert("Clear All Frames?", isPresented: $showingDeleteAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    frameStorage.clearAll()
                    undoStack.removeAll()
                    currentIndex = 0
                }
            } message: {
                Text("This will delete all captured frames. This cannot be undone.")
            }
            .sheet(isPresented: $showingExportSheet) {
                ExportSheet(frames: frameStorage.exportKeptFrames())
            }
        }
    }
    
    private func deleteFrame(_ frame: CapturedFrame) {
        guard let index = frameStorage.frames.firstIndex(where: { $0.id == frame.id }) else {
            return
        }
        
        // Record action for undo
        let action = ReviewAction(
            type: .delete(frame: frame, index: index),
            timestamp: Date()
        )
        undoStack.append(action)
        
        frameStorage.deleteFrame(frame)
        if currentIndex >= frameStorage.frames.count {
            currentIndex = max(0, frameStorage.frames.count - 1)
        }
    }
    
    private func toggleKeep(_ frame: CapturedFrame) {
        // Record action for undo
        let action = ReviewAction(
            type: .toggleKeep(frameId: frame.id, previousState: frame.kept),
            timestamp: Date()
        )
        undoStack.append(action)
        
        frameStorage.toggleKeep(frame)
    }
    
    private func performUndo() {
        guard let lastAction = undoStack.popLast() else { return }
        
        switch lastAction.type {
        case .delete(let frame, let index):
            frameStorage.restoreFrame(frame, at: index)
            currentIndex = min(index, frameStorage.frames.count - 1)
            
        case .toggleKeep(let frameId, let previousState):
            if let frame = frameStorage.frames.first(where: { $0.id == frameId }) {
                if frame.kept != previousState {
                    frameStorage.toggleKeep(frame)
                }
            }
        }
    }
}

struct FrameCard: View {
    let frame: CapturedFrame
    let geometry: GeometryProxy
    let offset: CGFloat
    let index: Int
    let currentIndex: Int
    let onDelete: () -> Void
    let onKeep: () -> Void
    
    var body: some View {
        VStack {
            if let imageData = frame.imageData,
               let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: geometry.size.width * 0.9)
                    .cornerRadius(12)
                    .shadow(radius: 5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(frame.kept ? Color.green : Color.orange, lineWidth: 3)
                    )
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(maxWidth: geometry.size.width * 0.9, maxHeight: geometry.size.height * 0.7)
                    .cornerRadius(12)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                    )
            }
        }
        .offset(x: CGFloat(index - currentIndex) * geometry.size.width + offset)
        .opacity(index == currentIndex ? 1 : 0.3)
        .scaleEffect(index == currentIndex ? 1 : 0.8)
    }
}

struct ExportSheet: View {
    let frames: [CapturedFrame]
    @Environment(\.dismiss) var dismiss
    @AppStorage("scout_api_key") private var apiKey: String = ""
    @AppStorage("scout_project") private var project: String = ""
    
    @State private var isUploading = false
    @State private var uploadProgress: UploadProgress?
    @State private var errorMessage: String?
    @State private var uploadComplete = false
    @State private var successCount = 0
    @State private var failureCount = 0
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if uploadComplete {
                    Image(systemName: failureCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(failureCount == 0 ? .green : .orange)
                    
                    Text(failureCount == 0 ? "Upload Complete!" : "Upload Finished with Errors")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    VStack(spacing: 8) {
                        if successCount > 0 {
                            Text("✓ \(successCount) frame\(successCount != 1 ? "s" : "") uploaded and marked as null")
                                .font(.subheadline)
                                .foregroundColor(.green)
                        }
                        
                        if failureCount > 0 {
                            Text("✗ \(failureCount) frame\(failureCount != 1 ? "s" : "") failed to upload")
                                .font(.subheadline)
                                .foregroundColor(.red)
                        }
                        
                        if let error = errorMessage, failureCount > 0 {
                            Text("Last error: \(error)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.top, 4)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                } else {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                    
                    Text("\(frames.count) frame\(frames.count != 1 ? "s" : "") ready to upload")
                        .font(.title2)
                    
                    Text("Upload these null frames to Roboflow and mark them as negative examples.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    if let progress = uploadProgress {
                        VStack(spacing: 12) {
                            ProgressView(value: progress.percentage) {
                                Text("Uploading \(progress.current) of \(progress.total)")
                                    .font(.subheadline)
                            }
                            .progressViewStyle(.linear)
                            
                            Text(progress.currentImageName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal)
                    }
                    
                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    
                    if apiKey.isEmpty || project.isEmpty {
                        Text("⚠️ Configure API Key and Project ID in Settings")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    
                    Button(action: {
                        uploadFrames()
                    }) {
                        Text(isUploading ? "Uploading..." : "Upload & Nullify")
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(isUploading || apiKey.isEmpty || project.isEmpty ? Color.gray : Color.blue)
                            .cornerRadius(12)
                    }
                    .disabled(isUploading || apiKey.isEmpty || project.isEmpty)
                    .padding(.horizontal)
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Upload & Nullify")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(uploadComplete ? "Done" : "Cancel") {
                        dismiss()
                    }
                    .disabled(isUploading)
                }
            }
        }
    }
    
    private func uploadFrames() {
        guard !project.isEmpty, !apiKey.isEmpty else {
            errorMessage = "Missing configuration"
            return
        }
        
        isUploading = true
        errorMessage = nil
        successCount = 0
        failureCount = 0
        
        Task {
            for (index, frame) in frames.enumerated() {
                guard let imageData = frame.imageData,
                      let image = UIImage(data: imageData) else {
                    await MainActor.run {
                        failureCount += 1
                    }
                    continue
                }
                
                let imageName = "null_\(frame.id.uuidString).jpg"
                
                await MainActor.run {
                    uploadProgress = UploadProgress(
                        current: index + 1,
                        total: frames.count,
                        currentImageName: imageName
                    )
                }
                
                do {
                    _ = try await RoboflowService.shared.uploadAndNullify(
                        image: image,
                        imageName: imageName,
                        project: project,
                        apiKey: apiKey
                    )
                    
                    await MainActor.run {
                        successCount += 1
                    }
                } catch {
                    await MainActor.run {
                        failureCount += 1
                        errorMessage = error.localizedDescription
                    }
                }
                
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            
            await MainActor.run {
                isUploading = false
                uploadComplete = true
            }
        }
    }
}

#Preview {
    FrameReviewView()
        .environmentObject(FrameStorage())
}
