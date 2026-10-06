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
    @State private var isScanning = false
    @State private var isRecording = false
    @State private var errorMessage: String?
    @State private var lastCaptureTime: Date?
    @State private var lastSavedHash: Data?
    @State private var captureCount = 0
    @State private var showThresholdSheet = false
    
    private let frameCheckInterval: TimeInterval = 0.5
    private let similarityThreshold: Double = 0.85
    
    var body: some View {
        NavigationView {
            ZStack {
                CameraPreview(session: cameraManager.session)
                    .edgesIgnoringSafeArea(.all)
                
                VStack {
                    HStack {
                        Spacer()
                        
                        ThresholdBadge(
                            thresholdManager: thresholdManager,
                            showSheet: $showThresholdSheet
                        )
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
                        if !isScanning {
                            Text("Tap Start to begin detection")
                                .font(.subheadline)
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial)
                                .cornerRadius(20)
                        } else {
                            Text(isRecording ? "Recording frames..." : "Hold button to save frames")
                                .font(.subheadline)
                                .fontWeight(isRecording ? .bold : .regular)
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(isRecording ? AnyShapeStyle(Color.red.opacity(0.9)) : AnyShapeStyle(.ultraThinMaterial))
                                .cornerRadius(20)
                                .animation(.easeInOut(duration: 0.3), value: isRecording)
                        }
                        
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
                            .disabled(!isScanning)
                            
                            if !isScanning {
                                Button(action: {
                                    startScanning()
                                }) {
                                    Text("Start")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                        .frame(width: 120, height: 50)
                                        .background(modelManager.currentModel != nil ? Color.blue : Color.gray)
                                        .cornerRadius(25)
                                }
                                .disabled(modelManager.currentModel == nil)
                            } else {
                                Button(action: {}) {
                                    Circle()
                                        .fill(isRecording ? Color.red : Color.white)
                                        .frame(width: 70, height: 70)
                                        .overlay(
                                            Circle()
                                                .stroke(Color.white, lineWidth: 4)
                                        )
                                        .scaleEffect(isRecording ? 1.1 : 1.0)
                                        .animation(.easeInOut(duration: 0.2), value: isRecording)
                                }
                                .simultaneousGesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { _ in
                                            if !isRecording {
                                                startRecording()
                                            }
                                        }
                                        .onEnded { _ in
                                            stopRecording()
                                        }
                                )
                            }
                            
                            Text("\(captureCount)")
                                .font(.title2)
                                .fontWeight(.bold)
                                .frame(width: 60, height: 60)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        
                        if isScanning {
                            Button(action: {
                                stopScanning()
                            }) {
                                Text("Stop Scouting")
                                    .font(.subheadline)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(Color.red.opacity(0.8))
                                    .cornerRadius(20)
                            }
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Scout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isScanning {
                        ProgressView()
                    }
                }
            }
            .onAppear {
                cameraManager.checkPermissions()
            }
            .sheet(isPresented: $showThresholdSheet) {
                ThresholdControlSheet(
                    thresholdManager: thresholdManager,
                    modelManager: modelManager,
                    isPresented: $showThresholdSheet
                )
            }
        }
    }
    
    private func startScanning() {
        guard modelManager.currentModel != nil else {
            errorMessage = "No model loaded. Download a model in Settings first."
            return
        }
        
        errorMessage = nil
        isScanning = true
        captureCount = frameStorage.frames.count
        cameraManager.startSession()
        scheduleScan()
    }
    
    private func stopScanning() {
        isScanning = false
        isRecording = false
        lastSavedHash = nil
        cameraManager.stopSession()
    }
    
    private func startRecording() {
        isRecording = true
        lastCaptureTime = nil
        lastSavedHash = nil
    }
    
    private func stopRecording() {
        isRecording = false
        lastSavedHash = nil
    }
    
    private func scheduleScan() {
        guard isScanning else { return }
        
        Task {
            try? await Task.sleep(nanoseconds: UInt64(frameCheckInterval * 1_000_000_000))
            await performScan()
            scheduleScan()
        }
    }
    
    private func performScan() async {
        guard let image = cameraManager.captureFrame() else {
            return
        }
        
        guard modelManager.currentModel != nil else {
            await MainActor.run {
                errorMessage = "No model loaded. Please download a model in Settings."
                stopScanning()
            }
            return
        }
        
        do {
            let detections = try await modelManager.detect(image: image)
            
            // Only save if recording AND detections found AND different from last saved
            if isRecording && !detections.isEmpty {
                let now = Date()
                let currentHash = perceptualHash(image: image)
                
                await MainActor.run {
                    // Re-check isRecording after in-flight detect to prevent save after release
                    guard isRecording else { return }
                    
                    // Basic debounce
                    if let lastCapture = lastCaptureTime {
                        guard now.timeIntervalSince(lastCapture) >= frameCheckInterval else {
                            return
                        }
                    }
                    
                    // Similarity check - skip if too similar to last saved frame
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
                    
                    // Save frame
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
                stopScanning()
            }
        }
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
        
        latestFrame = UIImage(cgImage: cgImage)
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

#Preview {
    CameraView()
        .environmentObject(FrameStorage())
}
