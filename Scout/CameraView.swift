import SwiftUI
import AVFoundation
import UIKit

// "The world is yours" - Nas (probably)
// Camera capture and detection view

struct CameraView: View {
    @EnvironmentObject var frameStorage: FrameStorage
    
    @ObservedObject var modelManager = ModelManager.shared
    @ObservedObject var thresholdManager = ThresholdManager.shared
    @StateObject private var cameraManager = CameraManager()
    @State private var isCapturing = false
    @State private var errorMessage: String?
    @State private var lastCaptureTime: Date?
    @State private var lastSavedHash: Data?
    @State private var captureCount = 0
    @State private var showThresholdSheet = false
    @State private var showModelPicker = false
    @State private var currentDetections: [Detection] = []
    @State private var lastDetectionCount = 0
    @State private var hapticCooldownUntil: Date = Date.distantPast
    @State private var isLoadingModel = false
    
    private let frameCheckInterval: TimeInterval = 0.1
    private let similarityThreshold: Double = 0.85
    private let hapticCooldown: TimeInterval = 1.0
    
    var body: some View {
        NavigationView {
            ZStack {
                CameraPreview(session: cameraManager.session)
                    .edgesIgnoringSafeArea(.all)
                
                if isLoadingModel {
                    LoadingModelOverlay()
                } else if modelManager.currentModel == nil {
                    NoModelOverlay(showModelPicker: $showModelPicker)
                } else {
                    DetectionOverlay(
                        detections: currentDetections,
                        imageSize: cameraManager.latestFrameSize,
                        classColors: modelManager.classColors
                    )
                }
                
                VStack {
                    HStack {
                        Spacer()
                        
                        VStack(spacing: 8) {
                            ModelBadge(
                                modelManager: modelManager,
                                showSheet: $showModelPicker
                            )
                            
                            ThresholdBadge(
                                thresholdManager: thresholdManager,
                                showSheet: $showThresholdSheet
                            )
                        }
                        .padding(.top, 60)
                        .padding(.trailing, 16)
                    }
                    
                    Spacer()
                    
                    if let error = errorMessage {
                        Text(error)
                            .padding()
                            .background(.red.opacity(0.9))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                            .padding()
                    }
                    
                    VStack(spacing: 16) {
                        Text(isCapturing ? "Saving frames..." : "Hold button to save frames")
                            .font(.subheadline)
                            .fontWeight(isCapturing ? .bold : .regular)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(isCapturing ? AnyShapeStyle(Color.red.opacity(0.9)) : AnyShapeStyle(.ultraThinMaterial))
                            .cornerRadius(20)
                            .animation(.easeInOut(duration: 0.3), value: isCapturing)
                        
                        HStack(spacing: 20) {
                            Button(action: {
                                cameraManager.switchCamera()
                            }) {
                                Image(systemName: "arrow.triangle.2.circlepath.camera")
                                    .font(.title2)
                                    .padding()
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                            }
                            
                            Button(action: {}) {
                                Image(systemName: "camera.circle.fill")
                                    .font(.system(size: 70))
                                    .foregroundColor(isCapturing ? .red : .white)
                                    .scaleEffect(isCapturing ? 1.1 : 1.0)
                                    .animation(.easeInOut(duration: 0.2), value: isCapturing)
                            }
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { _ in
                                        if !isCapturing {
                                            startCapturing()
                                        }
                                    }
                                    .onEnded { _ in
                                        stopCapturing()
                                    }
                            )
                            
                            Text("\(captureCount)")
                                .font(.title2)
                                .fontWeight(.bold)
                                .frame(width: 60, height: 60)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Scout")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                cameraManager.checkPermissions()
                captureCount = frameStorage.frames.count
                
                if modelManager.hasConfiguredModel() {
                    if modelManager.currentModel == nil {
                        isLoadingModel = true
                    } else {
                        startDetection()
                    }
                } else {
                    showModelPicker = true
                }
            }
            .onChange(of: modelManager.currentModel) { newModel in
                if newModel != nil {
                    isLoadingModel = false
                    startDetection()
                }
            }
            .sheet(isPresented: $showThresholdSheet) {
                ThresholdControlSheet(
                    thresholdManager: thresholdManager,
                    modelManager: modelManager,
                    isPresented: $showThresholdSheet
                )
            }
            .sheet(isPresented: $showModelPicker) {
                ModelPickerSheet(
                    modelManager: modelManager,
                    oauthManager: OAuthManager.shared,
                    isPresented: $showModelPicker
                )
            }
        }
    }
    
    private func startDetection() {
        guard modelManager.currentModel != nil else {
            return
        }
        
        errorMessage = nil
        cameraManager.startSession()
        scheduleDetection()
    }
    
    private func startCapturing() {
        isCapturing = true
        lastCaptureTime = nil
        lastSavedHash = nil
    }
    
    private func stopCapturing() {
        isCapturing = false
        lastSavedHash = nil
    }
    
    private func scheduleDetection() {
        guard modelManager.currentModel != nil else { return }
        
        Task {
            try? await Task.sleep(nanoseconds: UInt64(frameCheckInterval * 1_000_000_000))
            await performDetection()
            scheduleDetection()
        }
    }
    
    private func performDetection() async {
        guard let image = cameraManager.captureFrame() else {
            return
        }
        
        guard modelManager.currentModel != nil else {
            await MainActor.run {
                errorMessage = "No model loaded."
                cameraManager.stopSession()
            }
            return
        }
        
        do {
            let detections = try await modelManager.detect(image: image)
            
            await MainActor.run {
                currentDetections = detections
                
                if !detections.isEmpty && lastDetectionCount == 0 {
                    fireHapticIfReady()
                }
                lastDetectionCount = detections.count
            }
            
            if isCapturing && !detections.isEmpty {
                let now = Date()
                let currentHash = perceptualHash(image: image)
                
                await MainActor.run {
                    guard isCapturing else { return }
                    
                    if let lastCapture = lastCaptureTime {
                        guard now.timeIntervalSince(lastCapture) >= frameCheckInterval else {
                            return
                        }
                    }
                    
                    if let lastHash = lastSavedHash,
                       let currentHash = currentHash {
                        let hammingDist = hammingDistance(lastHash, currentHash)
                        let maxDistance = Double(lastHash.count * 8)
                        let similarity = 1.0 - (Double(hammingDist) / maxDistance)
                        if similarity > similarityThreshold {
                            return
                        }
                        lastSavedHash = currentHash
                    } else {
                        lastSavedHash = currentHash
                    }
                    
                    lastCaptureTime = now
                    
                    let imageData = image.jpegData(compressionQuality: 0.8)
                    let frame = CapturedFrame(
                        timestamp: now,
                        detections: detections,
                        imageData: imageData
                    )
                    
                    frameStorage.addFrame(frame)
                    captureCount = frameStorage.frames.count
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func fireHapticIfReady() {
        let now = Date()
        guard now >= hapticCooldownUntil else { return }
        
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        
        hapticCooldownUntil = now.addingTimeInterval(hapticCooldown)
    }
    
    // "It ain't where you from, it's where you at" ~Nas (probably)
    // Perceptual hash for image similarity
    private func perceptualHash(image: UIImage, hashSize: Int = 8) -> Data? {
        guard let resized = resizeImage(image: image, size: CGSize(width: hashSize, height: hashSize)),
              let cgImage = resized.cgImage else {
            return nil
        }
        
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8
        
        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var grayValues: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * bytesPerPixel
                let r = pixelData[offset]
                let g = pixelData[offset + 1]
                let b = pixelData[offset + 2]
                let rPart: Double = Double(r) * 0.299
                let gPart: Double = Double(g) * 0.587
                let bPart: Double = Double(b) * 0.114
                let gray = UInt8(rPart + gPart + bPart)
                grayValues.append(gray)
            }
        }
        
        let average = UInt8(grayValues.reduce(0) { $0 + Int($1) } / grayValues.count)
        
        var hash = Data()
        var byte: UInt8 = 0
        var bitIndex = 0
        
        for gray in grayValues {
            if gray >= average {
                byte |= (1 << (7 - bitIndex))
            }
            bitIndex += 1
            if bitIndex == 8 {
                hash.append(byte)
                byte = 0
                bitIndex = 0
            }
        }
        
        if bitIndex > 0 {
            hash.append(byte)
        }
        
        return hash
    }
    
    private func resizeImage(image: UIImage, size: CGSize) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        image.draw(in: CGRect(origin: .zero, size: size))
        return UIGraphicsGetImageFromCurrentImageContext()
    }
    
    private func hammingDistance(_ data1: Data, _ data2: Data) -> Int {
        guard data1.count == data2.count else { return Int.max }
        
        var distance = 0
        for i in 0..<data1.count {
            var xor = data1[i] ^ data2[i]
            while xor != 0 {
                distance += 1
                xor &= xor - 1
            }
        }
        return distance
    }
}

class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private var videoOutput = AVCaptureVideoDataOutput()
    private var currentCamera: AVCaptureDevice.Position = .back
    private var currentInput: AVCaptureDeviceInput?
    private var latestFrame: UIImage?
    @Published var latestFrameSize: CGSize = .zero
    
    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async {
                        self?.setupCamera()
                    }
                }
            }
        default:
            break
        }
    }
    
    private func setupCamera() {
        session.beginConfiguration()
        
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentCamera),
              let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            return
        }
        
        if let currentInput = currentInput {
            session.removeInput(currentInput)
        }
        
        if session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
        }
        
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        
        session.commitConfiguration()
    }
    
    func startSession() {
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }
    
    func stopSession() {
        if session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.stopRunning()
            }
        }
    }
    
    func switchCamera() {
        currentCamera = currentCamera == .back ? .front : .back
        setupCamera()
    }
    
    func captureFrame() -> UIImage? {
        return latestFrame
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()
        
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }
        
        let uiImage = UIImage(cgImage: cgImage)
        latestFrame = uiImage
        
        DispatchQueue.main.async { [weak self] in
            self?.latestFrameSize = uiImage.size
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        
        context.coordinator.previewLayer = previewLayer
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.previewLayer?.frame = uiView.bounds
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}

struct NoModelOverlay: View {
    @Binding var showModelPicker: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            VStack(spacing: 16) {
                Image(systemName: "cube.box")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)
                
                Text("No Model Loaded")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Choose a Core ML model to start detecting objects")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                Button(action: {
                    showModelPicker = true
                }) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Choose Model")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .cornerRadius(12)
                }
            }
            .padding(32)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            .shadow(radius: 10)
            
            Spacer()
        }
        .padding()
    }
}

struct ModelBadge: View {
    @ObservedObject var modelManager: ModelManager
    @Binding var showSheet: Bool
    
    private var displayText: String {
        if modelManager.isDownloading {
            return "⏳"
        } else if let version = modelManager.loadedVersion {
            return "v\(version)"
        } else {
            return "No Model"
        }
    }
    
    var body: some View {
        Button(action: {
            showSheet = true
        }) {
            HStack(spacing: 6) {
                Image(systemName: "cube.box")
                    .font(.caption)
                Text(displayText)
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(modelManager.currentModel != nil ? Color.green.opacity(0.3) : Color.gray.opacity(0.3), lineWidth: 1)
            )
        }
        .foregroundColor(.primary)
    }
}

struct ThresholdBadge: View {
    @ObservedObject var thresholdManager: ThresholdManager
    @Binding var showSheet: Bool
    
    var body: some View {
        Button(action: {
            showSheet = true
        }) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
                Text("\(Int(thresholdManager.overallThreshold * 100))%")
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.blue.opacity(0.3), lineWidth: 1)
            )
        }
        .foregroundColor(.primary)
    }
}

struct DetectionOverlay: View {
    let detections: [Detection]
    let imageSize: CGSize
    let classColors: [String: String]
    
    @State private var lastLogTime: Date = Date.distantPast
    
    var body: some View {
        GeometryReader { geometry in
            let viewSize = geometry.size
            
            let now = Date()
            let _: Void = {
                if now.timeIntervalSince(lastLogTime) > 1.0 {
                    DispatchQueue.main.async {
                        lastLogTime = now
                        print("🔵 [ScoutDetect] Overlay: imageSize=\(Int(imageSize.width))×\(Int(imageSize.height)), viewSize=\(Int(viewSize.width))×\(Int(viewSize.height)), dets=\(detections.count)")
                    }
                }
            }()
            
            ForEach(detections) { detection in
                let box = convertToViewCoordinates(
                    detection: detection,
                    imageSize: imageSize,
                    viewSize: viewSize
                )
                
                let boxColor = colorForClass(detection.className)
                
                Rectangle()
                    .stroke(boxColor, lineWidth: 2)
                    .frame(width: box.width, height: box.height)
                    .position(x: box.x, y: box.y)
                    .overlay(
                        Text("\(detection.className) \(Int(detection.confidence * 100))%")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(boxColor.opacity(0.8))
                            .cornerRadius(4)
                            .position(x: box.x, y: box.y - box.height / 2 - 12)
                    )
            }
        }
    }
    
    private func colorForClass(_ className: String) -> Color {
        if let hexColor = classColors[className] {
            return Color(hex: hexColor) ?? .green
        }
        
        let hash = abs(className.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.8, brightness: 0.9)
    }
    
    private func convertToViewCoordinates(
        detection: Detection,
        imageSize: CGSize,
        viewSize: CGSize
    ) -> (x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return (0, 0, 0, 0)
        }
        
        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = viewSize.width / viewSize.height
        
        let scale: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
        
        if imageAspect > viewAspect {
            scale = viewSize.width / imageSize.width
            offsetX = 0
            offsetY = (viewSize.height - imageSize.height * scale) / 2
        } else {
            scale = viewSize.height / imageSize.height
            offsetX = (viewSize.width - imageSize.width * scale) / 2
            offsetY = 0
        }
        
        let x = CGFloat(detection.x) * scale + offsetX
        let y = CGFloat(detection.y) * scale + offsetY
        let width = CGFloat(detection.width) * scale
        let height = CGFloat(detection.height) * scale
        
        return (x, y, width, height)
    }
}

struct LoadingModelOverlay: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.blue)
                
                Text("Loading Model")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Preparing on-device detection...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .background(.ultraThinMaterial)
            .cornerRadius(20)
            .shadow(radius: 10)
            
            Spacer()
        }
        .padding()
    }
}

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        var rgb: UInt64 = 0
        
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }
        
        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0
        
        self.init(red: r, green: g, blue: b)
    }
}

#Preview {
    CameraView()
        .environmentObject(FrameStorage())
}
