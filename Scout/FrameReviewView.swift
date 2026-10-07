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
    
    private var unreviewedFrames: [CapturedFrame] {
        frameStorage.frames.filter { !$0.reviewed }
    }
    
    private var reviewedKeptCount: Int {
        frameStorage.frames.filter { $0.reviewed && $0.kept }.count
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
                    if !frameStorage.frames.isEmpty && unreviewedFrames.isEmpty {
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
                        .offset(y: CGFloat(index) * 8)
                        .scaleEffect(1.0 - Double(index) * 0.05)
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
    @State private var longPressTask: Task<Void, Never>?
    
    private var rotationAngle: Double {
        Double(offset.width) / 20.0
    }
    
    private var stampOpacity: Double {
        min(abs(offset.width) / 120.0, 1.0)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let imageData = frame.imageData,
                   let uiImage = UIImage(data: imageData) {
                    VStack {
                        ZStack {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                            
                            // Raw camera frame - boxes overlaid, NEVER burned in
                            DetectionBoxesView(
                                detections: frame.detections,
                                imageSize: uiImage.size,
                                classColors: classColors,
                                scalingMode: .aspectFit,
                                opacity: isLongPressing ? 0.1 : 1.0
                            )
                            
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
                        .frame(maxWidth: geometry.size.width * 0.85)
                        .cornerRadius(12)
                        .shadow(radius: index == 0 ? 8 : 4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white, lineWidth: 3)
                        )
                    }
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(maxWidth: geometry.size.width * 0.85)
                        .cornerRadius(12)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                        )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .offset(x: offset.width, y: offset.height)
            .rotationEffect(.degrees(rotationAngle))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if index != 0 { return }
                        
                        if touchStartTime == nil {
                            touchStartTime = Date()
                            initialTouchLocation = gesture.location
                            
                            longPressTask?.cancel()
                            longPressTask = Task {
                                try? await Task.sleep(nanoseconds: 250_000_000)
                                
                                if let start = initialTouchLocation,
                                   let current = initialTouchLocation {
                                    let distance = hypot(current.x - start.x, current.y - start.y)
                                    if distance < 10 {
                                        await MainActor.run {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                isLongPressing = true
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        
                        if let start = initialTouchLocation {
                            let distance = hypot(gesture.location.x - start.x, gesture.location.y - start.y)
                            if distance > 10 {
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
                            flyOffScreen(direction: .right, geometry: geometry)
                        } else if offset.width < -threshold || (fastFlick && offset.width < 0) {
                            flyOffScreen(direction: .left, geometry: geometry)
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                offset = .zero
                            }
                        }
                    }
            )
        }
    }
    
    private func flyOffScreen(direction: SwipeDirection, geometry: GeometryProxy) {
        let offScreenX = direction == .right ? geometry.size.width * 2 : -geometry.size.width * 2
        withAnimation(.easeOut(duration: 0.3)) {
            offset = CGSize(width: offScreenX, height: offset.height)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            onSwipe(direction)
            offset = .zero
        }
    }
}

#Preview {
    FrameReviewView()
        .environmentObject(FrameStorage())
}
