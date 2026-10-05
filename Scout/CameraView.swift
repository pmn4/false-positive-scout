import SwiftUI
import AVFoundation
import UIKit

// "The world is yours" - Nas (probably)
// Camera capture and detection view

struct CameraView: View {
    @EnvironmentObject var frameStorage: FrameStorage
    @AppStorage("scout_model_id") private var modelId: String = ""
    @AppStorage("scout_api_key") private var apiKey: String = ""
    @AppStorage("scout_confidence") private var confidence: Int = 40
    
    @StateObject private var cameraManager = CameraManager()
    @State private var isScanning = false
    @State private var errorMessage: String?
    @State private var lastCaptureTime: Date?
    @State private var captureCount = 0
    
    private let debounceInterval: TimeInterval = 3.0
    
    var body: some View {
        NavigationView {
            ZStack {
                CameraPreview(session: cameraManager.session)
                    .edgesIgnoringSafeArea(.all)
                
                VStack {
                    Spacer()
                    
                    if let error = errorMessage {
                        Text(error)
                            .padding()
                            .background(.red.opacity(0.9))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                            .padding()
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
                        .disabled(isScanning)
                        
                        Button(action: {
                            if isScanning {
                                stopScanning()
                            } else {
                                startScanning()
                            }
                        }) {
                            Text(isScanning ? "Stop" : "Start")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(width: 120, height: 50)
                                .background(isScanning ? Color.red : Color.blue)
                                .cornerRadius(25)
                        }
                        .disabled(modelId.isEmpty || apiKey.isEmpty)
                        
                        Text("\(captureCount)")
                            .font(.title2)
                            .fontWeight(.bold)
                            .frame(width: 60, height: 60)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
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
        }
    }
    
    private func startScanning() {
        guard !modelId.isEmpty, !apiKey.isEmpty else {
            errorMessage = "Configure Model ID and API Key in Settings"
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
        cameraManager.stopSession()
    }
    
    private func scheduleScan() {
        guard isScanning else { return }
        
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await performScan()
            scheduleScan()
        }
    }
    
    private func performScan() async {
        guard let image = cameraManager.captureFrame() else {
            return
        }
        
        let config = RoboflowConfig(
            modelId: modelId,
            apiKey: apiKey,
            confidenceThreshold: confidence
        )
        
        do {
            let detections = try await RoboflowService.shared.detect(image: image, config: config)
            
            // Only save if detections found and debounce interval has passed
            if !detections.isEmpty {
                let now = Date()
                if let lastCapture = lastCaptureTime {
                    guard now.timeIntervalSince(lastCapture) >= debounceInterval else {
                        return
                    }
                }
                
                lastCaptureTime = now
                
                // Save frame
                let imageData = image.jpegData(compressionQuality: 0.8)
                let frame = CapturedFrame(
                    timestamp: now,
                    detections: detections,
                    imageData: imageData
                )
                
                await MainActor.run {
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

#Preview {
    CameraView()
        .environmentObject(FrameStorage())
}
