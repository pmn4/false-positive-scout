import SwiftUI

// "Whose world is this? The world is yours" - Nas (probably)
// Configuration interface for Roboflow credentials

struct SettingsView: View {
    @AppStorage("scout_model_id") private var modelId: String = ""
    @AppStorage("scout_api_key") private var apiKey: String = ""
    @AppStorage("scout_confidence") private var confidence: Int = 40
    
    @State private var showingApiKey = false
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text("Configure your Roboflow object detection model to start capturing null frames.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } header: {
                    Text("About")
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Model ID")
                            .font(.headline)
                        
                        TextField("workspace/version", text: $modelId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        
                        Text("Format: workspace/version (e.g., my-workspace/3)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key")
                            .font(.headline)
                        
                        HStack {
                            if showingApiKey {
                                TextField("Your Roboflow API key", text: $apiKey)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("Your Roboflow API key", text: $apiKey)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            
                            Button(action: {
                                showingApiKey.toggle()
                            }) {
                                Image(systemName: showingApiKey ? "eye.slash" : "eye")
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Text("Get your API key from Roboflow Settings")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Roboflow Configuration")
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Confidence Threshold")
                                .font(.headline)
                            Spacer()
                            Text("\(confidence)%")
                                .foregroundColor(.secondary)
                        }
                        
                        Slider(value: Binding(
                            get: { Double(confidence) },
                            set: { confidence = Int($0) }
                        ), in: 0...100, step: 5)
                        
                        Text("Lower values capture more detections, including weak false positives")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Detection Settings")
                }
                
                Section {
                    Link(destination: URL(string: "https://roboflow.com")!) {
                        HStack {
                            Text("Roboflow")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Link(destination: URL(string: "https://docs.roboflow.com")!) {
                        HStack {
                            Text("Documentation")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Resources")
                }
                
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("License")
                        Spacer()
                        Text("MIT")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("About Scout")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scout helps you collect null frames (false positives) to improve your object detection model.")
                        
                        Text("Point the camera at scenes where nothing should be detected. When your model incorrectly fires, Scout saves that frame.")
                        
                        Text("Review and export these frames, then upload them to Roboflow as negative examples.")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#Preview {
    SettingsView()
}
