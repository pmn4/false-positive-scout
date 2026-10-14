import SwiftUI

// "The bridge is over, the bridge is over" - Nas (probably)
// Tinder-style swipe deck for reviewing captured frames

struct FrameReviewView: View {
    @EnvironmentObject var frameStorage: FrameStorage
    @ObservedObject var modelManager = ModelManager.shared
    @State private var undoStack: [ReviewAction] = []
    @State private var showingExportSheet = false
    @State private var topCardOffset: CGSize = .zero
    @State private var isAnimatingButton = false
    @State private var showingClearLegacyAlert = false
    
    private var unreviewedFrames: [CapturedFrame] {
        frameStorage.frames.filter { !$0.reviewed }
    }
    
    private var reviewedKeptCount: Int {
        frameStorage.frames.filter { $0.reviewed && $0.kept }.count
    }
    
    private var legacyFramesCount: Int {
        frameStorage.frames.filter { $0.isLegacy }.count
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                if frameStorage.frames.isEmpty {
                    emptyStateView
                } else if unreviewedFrames.isEmpty {
                    allReviewedView
                } else {
                    reviewDeckView
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
                    if legacyFramesCount > 0 {
                        Button(action: {
                            showingClearLegacyAlert = true
                        }) {
                            Label("Clear \(legacyFramesCount) old", systemImage: "trash")
                                .font(.caption)
                        }
                    } else if !frameStorage.frames.isEmpty && unreviewedFrames.isEmpty {
                        Button(action: {
                            showingExportSheet = true
                        }) {
                            Image(systemName: "square.and.arrow.up.circle")
                        }
                        .disabled(reviewedKeptCount == 0)
                    }
                }
            }
            .sheet(isPresented: $showingExportSheet) {
                ExportSheet(frames: frameStorage.exportKeptFrames())
            }
            .alert("Clear Old Captures", isPresented: $showingClearLegacyAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Clear \(legacyFramesCount)", role: .destructive) {
                    clearLegacyFrames()
                }
            } message: {
                Text("Delete \(legacyFramesCount) captures saved before image dimensions were tracked? This cannot be undone.")
            }
        }
    }
    
    private var emptyStateView: some View {
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
    }
    
    private var allReviewedView: some View {
        VStack(spacing: 20) {
            Image(systemName: reviewedKeptCount > 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(reviewedKeptCount > 0 ? .green : .gray)
            
            Text("All reviewed")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("\(reviewedKeptCount) ready to upload")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            if reviewedKeptCount > 0 {
                Button(action: {
                    showingExportSheet = true
                }) {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("Upload & Nullify")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .cornerRadius(12)
                }
                .padding(.top, 8)
            }
        }
    }
    
    private var reviewDeckView: some View {
        GeometryReader { geometry in
            VStack(spacing: 20) {
                Text("\(unreviewedFrames.count) left to review")
                    .font(.headline)
                    .padding(.top)
                
                Spacer()
                
                ZStack {
                    ForEach(Array(unreviewedFrames.prefix(3).enumerated()), id: \.element.id) { index, frame in
                        SwipeCard(
                            frame: frame,
                            classColors: modelManager.classColors,
                            offset: index == 0 ? $topCardOffset : .constant(.zero),
                            onSwipe: { direction in
                                if index == 0 {
                                    handleSwipe(frame: frame, direction: direction)
                                }
                            },
                            index: index
                        )
                        .zIndex(Double(2 - index))
                        .allowsHitTesting(index == 0)
                        .id(frame.id)
                    }
                }
                .frame(height: 500)
                
                HStack(spacing: 40) {
                    Button(action: {
                        animateButtonSwipe(direction: .left, geometry: geometry)
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.red)
                    }
                    .disabled(isAnimatingButton)
                    
                    Button(action: {
                        animateButtonSwipe(direction: .right, geometry: geometry)
                    }) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.green)
                    }
                    .disabled(isAnimatingButton)
                }
                .padding(.bottom, 40)
                
                Spacer()
            }
        }
    }
    
    private func animateButtonSwipe(direction: SwipeDirection, geometry: GeometryProxy) {
        guard !isAnimatingButton, let frame = unreviewedFrames.first else { return }
        
        isAnimatingButton = true
        let offScreenX = direction == .right ? geometry.size.width * 2 : -geometry.size.width * 2
        
        withAnimation(.easeOut(duration: 0.3)) {
            topCardOffset = CGSize(width: offScreenX, height: 0)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            handleSwipe(frame: frame, direction: direction)
            topCardOffset = .zero
            isAnimatingButton = false
        }
    }
    
    private func handleSwipe(frame: CapturedFrame, direction: SwipeDirection) {
        let previousKept = frame.kept
        
        let action = ReviewAction(
            type: direction == .right ? .accept(frame: frame, previousKept: previousKept) : .reject(frame: frame, index: frameStorage.frames.firstIndex(where: { $0.id == frame.id }) ?? 0),
            timestamp: Date()
        )
        undoStack.append(action)
        
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        
        if direction == .right {
            frameStorage.markReviewed(frame, kept: true)
        } else {
            frameStorage.deleteFrame(frame)
        }
    }
    
    private func performUndo() {
        guard let lastAction = undoStack.popLast() else { return }
        
        switch lastAction.type {
        case .accept(let frame, let previousKept):
            frameStorage.undoReview(frame, previousKept: previousKept)
            
        case .reject(let frame, let index):
            frameStorage.restoreFrame(frame, at: index)
            
        case .delete, .toggleKeep:
            break
        }
    }
    
    private func clearLegacyFrames() {
        let legacyFrames = frameStorage.frames.filter { $0.isLegacy }
        for frame in legacyFrames {
            frameStorage.deleteFrame(frame)
        }
    }
}

enum SwipeDirection {
    case left
    case right
}

struct ReviewAction {
    enum ActionType {
        case delete(frame: CapturedFrame, index: Int)
        case toggleKeep(frameId: UUID, previousState: Bool)
        case accept(frame: CapturedFrame, previousKept: Bool)
        case reject(frame: CapturedFrame, index: Int)
    }
    
    let type: ActionType
    let timestamp: Date
}

struct SwipeCard: View {
    let frame: CapturedFrame
    let classColors: [String: String]
    @Binding var offset: CGSize
    let onSwipe: (SwipeDirection) -> Void
    let index: Int
    
    @State private var isLongPressing = false
    @State private var touchStartTime: Date?
    @State private var initialTouchLocation: CGPoint?
    @State private var hasMovedBeyondThreshold = false
    @State private var longPressTask: Task<Void, Never>?
    
    private var rotationAngle: Double {
        Double(offset.width) / 20.0
    }
    
    private var stampOpacity: Double {
        min(abs(offset.width) / 120.0, 1.0)
    }
    
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let imageData = frame.imageData,
                   let uiImage = UIImage(data: imageData) {
                    let size = cardSize(
                        for: uiImage.size,
                        in: CGSize(width: geometry.size.width * 0.85, height: geometry.size.height)
                    )
                    
                    ZStack {
                        ZStack {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: size.width, height: size.height)
                            
                            // Raw camera frame - boxes overlaid, NEVER burned in
                            DetectionBoxesView(
                                detections: frame.detections,
                                imageSize: uiImage.size,
                                classColors: classColors,
                                scalingMode: .aspectFit,
                                opacity: isLongPressing ? 0.1 : 1.0
                            )
                            .frame(width: size.width, height: size.height)
                            
                            if index == 0 {
                                if offset.width > 0 {
                                    Text("KEEP")
                                        .font(.system(size: 60, weight: .bold))
                                        .foregroundColor(.green)
                                        .rotationEffect(.degrees(-20))
                                        .opacity(stampOpacity)
                                } else if offset.width < 0 {
                                    Text("REJECT")
                                        .font(.system(size: 60, weight: .bold))
                                        .foregroundColor(.red)
                                        .rotationEffect(.degrees(20))
                                        .opacity(stampOpacity)
                                }
                            }
                        }
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.2), radius: index == 0 ? 12 : 6, x: 0, y: 4)
                        
                        if let modelProject = frame.modelProject {
                            let slug = modelProject.split(separator: "/").last.map(String.init) ?? modelProject
                            let versionText = frame.modelVersion.map { " v\($0)" } ?? ""
                            Text("\(slug)\(versionText)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(.top, 6)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
                    .offset(x: index == 0 ? offset.width : 0, y: index == 0 ? offset.height : CGFloat(index) * 12)
                    .scaleEffect(1.0 - Double(index) * 0.05, anchor: .bottom)
                    .rotationEffect(.degrees(index == 0 ? rotationAngle : 0))
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: geometry.size.width * 0.85, height: geometry.size.height * 0.8)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
                        .offset(y: CGFloat(index) * 12)
                        .scaleEffect(1.0 - Double(index) * 0.05, anchor: .bottom)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if index != 0 { return }
                        
                        if touchStartTime == nil {
                            touchStartTime = Date()
                            initialTouchLocation = gesture.location
                            hasMovedBeyondThreshold = false
                            
                            longPressTask?.cancel()
                            longPressTask = Task {
                                do {
                                    try await Task.sleep(nanoseconds: 250_000_000)
                                } catch {
                                    return
                                }
                                
                                guard !Task.isCancelled, !hasMovedBeyondThreshold else { return }
                                
                                await MainActor.run {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        isLongPressing = true
                                    }
                                }
                            }
                        }
                        
                        if let start = initialTouchLocation {
                            let distance = hypot(gesture.location.x - start.x, gesture.location.y - start.y)
                            if distance > 10 {
                                hasMovedBeyondThreshold = true
                                longPressTask?.cancel()
                                if !isLongPressing {
                                    offset = gesture.translation
                                }
                            }
                        }
                    }
                    .onEnded { gesture in
                        if index != 0 { return }
                        
                        longPressTask?.cancel()
                        touchStartTime = nil
                        initialTouchLocation = nil
                        hasMovedBeyondThreshold = false
                        
                        if isLongPressing {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isLongPressing = false
                            }
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                offset = .zero
                            }
                            return
                        }
                        
                        let threshold: CGFloat = 120.0
                        let velocity = CGSize(
                            width: gesture.predictedEndTranslation.width - gesture.translation.width,
                            height: gesture.predictedEndTranslation.height - gesture.translation.height
                        )
                        let fastFlick = abs(velocity.width) > 500
                        
                        if offset.width > threshold || (fastFlick && offset.width > 0) {
                            flyOffScreen(direction: .right, containerWidth: geometry.size.width)
                        } else if offset.width < -threshold || (fastFlick && offset.width < 0) {
                            flyOffScreen(direction: .left, containerWidth: geometry.size.width)
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                offset = .zero
                            }
                        }
                    }
            )
        }
    }
    
    private func cardSize(for imageSize: CGSize, in available: CGSize) -> CGSize {
        let imageAspect = imageSize.width / imageSize.height
        if imageAspect > available.width / available.height {
            return CGSize(width: available.width, height: available.width / imageAspect)
        } else {
            return CGSize(width: available.height * imageAspect, height: available.height)
        }
    }
    
    private func flyOffScreen(direction: SwipeDirection, containerWidth: CGFloat) {
        let offScreenX = direction == .right ? containerWidth * 2 : -containerWidth * 2
        withAnimation(.easeOut(duration: 0.3)) {
            offset = CGSize(width: offScreenX, height: offset.height)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onSwipe(direction)
            offset = .zero
        }
    }
}

struct UploadedBatchLink: Identifiable, Hashable {
    /// Stable id for ForEach (batch id when known, else project slug).
    let id: String
    let projectSlug: String
    let batchName: String
    let url: URL
    let hasBatchId: Bool
}

struct ExportSheet: View {
    let frames: [CapturedFrame]
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var frameStorage: FrameStorage
    @ObservedObject var oauthManager = OAuthManager.shared
    @AppStorage("scout_model_project") private var selectedModelProject: String = ""
    /// Injected for tests; defaults to live RoboflowService.
    var roboflowClient: RoboflowUploading = RoboflowService.shared
    
    // Retry list uses NullifyFailure from NullUploadOrchestrator.
    
    @Environment(\.openURL) private var openURL
    @State private var isUploading = false
    @State private var uploadProgress: UploadProgress?
    @State private var errorMessage: String?
    @State private var uploadComplete = false
    @State private var successCount = 0
    @State private var failureCount = 0
    @State private var partialSuccesses: [NullifyFailure] = []
    @State private var uploadedBatches: [UploadedBatchLink] = []
    @State private var isRetrying = false
    @State private var currentBatchName: String = ""
    
    private var canAuthenticate: Bool {
        oauthManager.isAuthenticated
    }
    
    private var canUpload: Bool {
        canAuthenticate && !frames.isEmpty
    }
    
    private func targetProject(for frame: CapturedFrame) -> String? {
        if let project = frame.modelProject, !project.isEmpty {
            return project
        }
        if !selectedModelProject.isEmpty {
            return selectedModelProject
        }
        return nil
    }
    
    private func projectSlug(_ projectId: String) -> String {
        projectId.split(separator: "/").last.map(String.init) ?? projectId
    }
    
        
    private var uploadTargetSummary: String {
        var counts: [String: Int] = [:]
        for frame in frames {
            let key = targetProject(for: frame).map(projectSlug) ?? "(unknown project)"
            counts[key, default: 0] += 1
        }
        let parts = counts.sorted { $0.key < $1.key }.map { slug, count in
            "\(count) frame\(count == 1 ? "" : "s") to \(slug)"
        }
        if parts.count == 1 {
            return "Uploading \(parts[0])"
        }
        return "Uploading " + parts.joined(separator: ", ")
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                if uploadComplete {
                    Image(systemName: failureCount == 0 && partialSuccesses.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(failureCount == 0 && partialSuccesses.isEmpty ? .green : .orange)
                    
                    Text(failureCount == 0 && partialSuccesses.isEmpty ? "Upload Complete!" : "Upload Finished")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    VStack(spacing: 12) {
                        if successCount > 0 {
                            Text("✓ \(successCount) frame\(successCount != 1 ? "s" : "") uploaded & marked as null")
                                .font(.subheadline)
                                .foregroundColor(.green)
                        }
                        
                        if !partialSuccesses.isEmpty {
                            VStack(spacing: 8) {
                                Text("⚠️ \(partialSuccesses.count) frame\(partialSuccesses.count != 1 ? "s" : "") uploaded but nullify failed")
                                    .font(.subheadline)
                                    .foregroundColor(.orange)
                                
                                Text("Images are in Roboflow but not marked as null. You can mark them as Null in the Roboflow UI, or retry below.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                Button(action: {
                                    retryNullify()
                                }) {
                                    Text(isRetrying ? "Retrying..." : "Retry Nullify")
                                        .font(.subheadline)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 8)
                                        .background(Color.orange)
                                        .cornerRadius(8)
                                }
                                .disabled(isRetrying)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(Color.orange.opacity(0.1))
                            .cornerRadius(12)
                        }
                        
                        if failureCount > 0 {
                            Text("✗ \(failureCount) frame\(failureCount != 1 ? "s" : "") failed to upload")
                                .font(.subheadline)
                                .foregroundColor(.red)
                        }
                        
                        if let error = errorMessage, (failureCount > 0 || !partialSuccesses.isEmpty) {
                            Text("Last error: \(error)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.top, 4)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    
                    if !uploadedBatches.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Open in Roboflow")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            ForEach(uploadedBatches) { batch in
                                Button {
                                    openURL(batch.url)
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "safari")
                                            .foregroundColor(.blue)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(batch.projectSlug)
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                                .foregroundColor(.primary)
                                            Text(batch.batchName)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            if !batch.hasBatchId {
                                                Text("Project Annotate page (batch id unavailable)")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "arrow.up.right")
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                    }
                                    .padding(12)
                                    .background(Color.blue.opacity(0.08))
                                    .cornerRadius(10)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
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
                    
                    Text(uploadTargetSummary)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    if let progress = uploadProgress {
                        VStack(spacing: 12) {
                            ProgressView(value: progress.percentage) {
                                Text(progress.stage.isEmpty
                                     ? "Uploading \(progress.current) of \(progress.total)"
                                     : progress.stage)
                                    .font(.subheadline)
                            }
                            .progressViewStyle(.linear)
                            
                            Text(progress.currentImageName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
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
                    
                    if !canAuthenticate {
                        Text("⚠️ Log in with Roboflow in Settings")
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
                            .background(isUploading || !canUpload ? Color.gray : Color.blue)
                            .cornerRadius(12)
                    }
                    .disabled(isUploading || !canUpload)
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
                    .disabled(isUploading || isRetrying)
                }
            }
        }
    }
    
    
    private func uploadFrames() {
        guard canAuthenticate else {
            errorMessage = "Please log in with Roboflow in Settings"
            return
        }

        currentBatchName = NullUploadOrchestrator.makeBatchName()
        isUploading = true
        errorMessage = nil
        uploadedBatches = []
        successCount = 0
        failureCount = 0
        partialSuccesses = []

        let framesToUpload = frames
        let selected = selectedModelProject
        let batch = currentBatchName
        let client = roboflowClient

        Task {
            let orchestrator = NullUploadOrchestrator(client: client, store: frameStorage)
            let run = await orchestrator.runUploadAndNullify(
                frames: framesToUpload,
                selectedModelProject: selected,
                batchName: batch
            ) { progress in
                uploadProgress = progress
            }

            await MainActor.run {
                successCount = run.successCount
                failureCount = run.failureCount
                partialSuccesses = run.nullifyFailures
                uploadedBatches = run.uploadedBatches
                errorMessage = run.errorMessage
                isUploading = false
                uploadComplete = true
                uploadProgress = nil
            }
        }
    }

    private func retryNullify() {
        guard !partialSuccesses.isEmpty else { return }

        isRetrying = true
        errorMessage = nil

        let toRetry = partialSuccesses
        let client = roboflowClient

        Task {
            let orchestrator = NullUploadOrchestrator(client: client, store: frameStorage)
            let outcome = await orchestrator.retryNullify(failures: toRetry)

            await MainActor.run {
                successCount += outcome.successCount
                partialSuccesses = outcome.remaining
                errorMessage = outcome.errorMessage
                isRetrying = false
            }
        }
    }
}


#Preview {
    FrameReviewView()
        .environmentObject(FrameStorage())
}
