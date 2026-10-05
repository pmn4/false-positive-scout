import SwiftUI

// "The bridge is over, the bridge is over" - Nas (probably)
// Fast swipe-through review interface for captured frames

struct FrameReviewView: View {
    @EnvironmentObject var frameStorage: FrameStorage
    @State private var currentIndex = 0
    @State private var offset: CGFloat = 0
    @State private var showingDeleteAlert = false
    @State private var showingExportSheet = false
    
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
                                                frameStorage.toggleKeep(frame)
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
                                        frameStorage.toggleKeep(frame)
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: {
                            showingExportSheet = true
                        }) {
                            Label("Export Kept Frames", systemImage: "square.and.arrow.up")
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
        frameStorage.deleteFrame(frame)
        if currentIndex >= frameStorage.frames.count {
            currentIndex = max(0, frameStorage.frames.count - 1)
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
    @State private var isExporting = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)
                
                Text("\(frames.count) frame\(frames.count != 1 ? "s" : "") ready to export")
                    .font(.title2)
                
                Text("Save these null frames to your Photos library, then upload them to Roboflow to improve your model.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                Button(action: {
                    exportFrames()
                }) {
                    Text(isExporting ? "Saving..." : "Save to Photos")
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(12)
                }
                .disabled(isExporting)
                .padding(.horizontal)
                
                Spacer()
            }
            .padding()
            .navigationTitle("Export Frames")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func exportFrames() {
        isExporting = true
        
        Task {
            for frame in frames {
                guard let imageData = frame.imageData,
                      let image = UIImage(data: imageData) else {
                    continue
                }
                
                UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            
            await MainActor.run {
                isExporting = false
                dismiss()
            }
        }
    }
}

#Preview {
    FrameReviewView()
        .environmentObject(FrameStorage())
}
