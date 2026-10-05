import SwiftUI

// "Whose world is this? The world is yours" - Nas (probably)
// OAuth-based configuration for Roboflow

struct SettingsView: View {
    @AppStorage("scout_project") private var project: String = ""
    @AppStorage("scout_api_key") private var apiKey: String = ""
    @AppStorage("scout_model_workspace") private var modelWorkspace: String = ""
    @AppStorage("scout_model_project") private var modelProject: String = ""
    @AppStorage("scout_model_version") private var modelVersion: String = ""
    @AppStorage("scout_confidence") private var confidence: Int = 40
    
    @ObservedObject var oauthManager = OAuthManager.shared
    @ObservedObject var modelManager = ModelManager.shared
    @State private var isSigningIn = false
    @State private var signInError: String?
    @State private var workspaces: [Workspace] = []
    @State private var projects: [Project] = []
    @State private var selectedWorkspace: Workspace?
    @State private var selectedModelProject: Project?
    @State private var modelVersions: [ModelVersion] = []
    @State private var isLoadingProjects = false
    @State private var isLoadingVersions = false
    @State private var loadError: String?
    
    // Helper to determine active auth method
    private var authStatus: String {
        if oauthManager.isAuthenticated {
            return "OAuth (Signed In)"
        } else if !apiKey.isEmpty {
            return "API Key"
        } else {
            return "Not Configured"
        }
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sign in with Roboflow (OAuth) or paste an API key for quick setup.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        HStack {
                            Text("Active Auth:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(authStatus)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(oauthManager.isAuthenticated ? .green : (!apiKey.isEmpty ? .orange : .red))
                        }
                    }
                } header: {
                    Text("About")
                }
                
                Section {
                    if oauthManager.isAuthenticated {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Signed in to Roboflow")
                            Spacer()
                        }
                        
                        Button(action: {
                            oauthManager.signOut()
                            workspaces = []
                            projects = []
                            selectedWorkspace = nil
                            project = ""
                        }) {
                            HStack {
                                Spacer()
                                Text("Sign Out")
                                    .foregroundColor(.red)
                                Spacer()
                            }
                        }
                    } else {
                        Button(action: {
                            signIn()
                        }) {
                            HStack {
                                Spacer()
                                if isSigningIn {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                        .padding(.trailing, 8)
                                }
                                Text(isSigningIn ? "Signing in..." : "Sign in with Roboflow")
                                    .fontWeight(.medium)
                                Spacer()
                            }
                        }
                        .disabled(isSigningIn)
                        
                        if let error = signInError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                } header: {
                    Text("Authentication (Option 1: OAuth)")
                } footer: {
                    Text("Preferred for production. Requires OAuth app setup with 9 scopes. Takes priority over API key when signed in.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key")
                            .font(.headline)
                        
                        SecureField("Your Roboflow API key", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(oauthManager.isAuthenticated)
                        
                        if oauthManager.isAuthenticated {
                            Text("⚠️ API key ignored while signed in with OAuth")
                                .font(.caption)
                                .foregroundColor(.orange)
                        } else {
                            Text("Alternative to OAuth. Get from Roboflow Settings > API")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Project ID")
                            .font(.headline)
                        
                        TextField("my-project", text: $project)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        
                        Text("Required for upload when using API key (optional for OAuth)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Authentication (Option 2: API Key)")
                } footer: {
                    Text("Quick clone-and-build path. No OAuth or Universal Links setup needed. Get API key from app.roboflow.com/settings/api")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if oauthManager.isAuthenticated {
                    Section {
                        if workspaces.isEmpty && projects.isEmpty {
                            Button(action: {
                                loadWorkspacesAndProjects()
                            }) {
                                HStack {
                                    Spacer()
                                    Text("Load Workspaces & Projects")
                                    Spacer()
                                }
                            }
                        } else {
                            if !workspaces.isEmpty {
                                Picker("Workspace", selection: $selectedWorkspace) {
                                    Text("Select workspace").tag(nil as Workspace?)
                                    ForEach(workspaces) { workspace in
                                        Text(workspace.name).tag(workspace as Workspace?)
                                    }
                                }
                                .onChange(of: selectedWorkspace) { newWorkspace in
                                    if let workspace = newWorkspace {
                                        loadProjects(workspace: workspace.url)
                                    } else {
                                        projects = []
                                        project = ""
                                    }
                                }
                            }
                            
                            if isLoadingProjects {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                    Text("Loading projects...")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                            } else if !projects.isEmpty {
                                Picker("Upload Project", selection: $project) {
                                    Text("Select project").tag("")
                                    ForEach(projects) { proj in
                                        Text(proj.name).tag(proj.id)
                                    }
                                }
                                
                                if !project.isEmpty {
                                    Text("Null frames will be uploaded to: \(projects.first(where: { $0.id == project })?.name ?? project)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        
                        if let error = loadError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    } header: {
                        Text("Upload Destination")
                    } footer: {
                        Text("Select the Roboflow project where null frames will be uploaded")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Section {
                        if !projects.isEmpty {
                            Picker("Detection Model Project", selection: $selectedModelProject) {
                                Text("Select project").tag(nil as Project?)
                                ForEach(projects) { proj in
                                    Text(proj.name).tag(proj as Project?)
                                }
                            }
                            .onChange(of: selectedModelProject) { newProject in
                                if let proj = newProject, let ws = selectedWorkspace {
                                    modelProject = proj.id
                                    modelWorkspace = ws.url
                                    loadModelVersions(workspace: ws.url, project: proj.id)
                                } else {
                                    modelVersions = []
                                    modelVersion = ""
                                }
                            }
                            
                            if isLoadingVersions {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                    Text("Loading models...")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                            } else if !modelVersions.isEmpty {
                                Picker("Model Version", selection: $modelVersion) {
                                    Text("Select version").tag("")
                                    ForEach(modelVersions) { version in
                                        Text(version.displayName).tag(version.id)
                                    }
                                }
                                
                                if !modelVersion.isEmpty && !modelWorkspace.isEmpty && !modelProject.isEmpty {
                                    if modelManager.isDownloading {
                                        HStack {
                                            ProgressView(value: modelManager.downloadProgress)
                                                .progressViewStyle(LinearProgressViewStyle())
                                            Text("\(Int(modelManager.downloadProgress * 100))%")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    } else if modelManager.currentModel != nil {
                                        HStack {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                            Text("Model ready for on-device inference")
                                                .font(.caption)
                                        }
                                    } else {
                                        Button(action: {
                                            downloadModel()
                                        }) {
                                            HStack {
                                                Spacer()
                                                Text("Download Model")
                                                Spacer()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        
                        if let error = loadError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    } header: {
                        Text("On-Device Detection Model")
                    } footer: {
                        Text("Download a Core ML model for on-device inference. Works offline after download.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
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
                }
            }
            .navigationTitle("Settings")
            .onAppear {
                if oauthManager.isAuthenticated && workspaces.isEmpty {
                    loadWorkspacesAndProjects()
                }
                
                // Auto-load cached model if configured
                loadCachedModelIfAvailable()
            }
        }
    }
    
    private func loadCachedModelIfAvailable() {
        guard !modelWorkspace.isEmpty, !modelProject.isEmpty, !modelVersion.isEmpty else {
            return
        }
        
        // Check if cache file exists
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RoboflowModels")
        let cacheURL = cacheDir.appendingPathComponent("\(modelWorkspace)_\(modelProject)_v\(modelVersion).mlpackage")
        
        guard FileManager.default.fileExists(atPath: cacheURL.path),
              modelManager.currentModel == nil else {
            return
        }
        
        // Load the cached model
        Task {
            do {
                let mlModel = try MLModel(contentsOf: cacheURL)
                await MainActor.run {
                    modelManager.currentModel = mlModel
                }
            } catch {
                print("Failed to load cached model: \(error)")
            }
        }
    }
    
    private func signIn() {
        isSigningIn = true
        signInError = nil
        
        Task {
            do {
                try await oauthManager.signIn()
                await MainActor.run {
                    isSigningIn = false
                    loadWorkspacesAndProjects()
                }
            } catch {
                await MainActor.run {
                    isSigningIn = false
                    signInError = error.localizedDescription
                }
            }
        }
    }
    
    private func loadWorkspacesAndProjects() {
        loadError = nil
        
        Task {
            do {
                let loadedWorkspaces = try await RoboflowService.shared.listWorkspaces()
                await MainActor.run {
                    self.workspaces = loadedWorkspaces
                    if let first = loadedWorkspaces.first {
                        self.selectedWorkspace = first
                        loadProjects(workspace: first.url)
                    }
                }
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                }
            }
        }
    }
    
    private func loadProjects(workspace: String) {
        isLoadingProjects = true
        loadError = nil
        
        Task {
            do {
                let loadedProjects = try await RoboflowService.shared.listProjects(workspace: workspace)
                await MainActor.run {
                    self.projects = loadedProjects
                    self.isLoadingProjects = false
                    
                    if !loadedProjects.isEmpty && project.isEmpty {
                        self.project = loadedProjects[0].id
                    }
                }
            } catch {
                await MainActor.run {
                    self.isLoadingProjects = false
                    self.loadError = error.localizedDescription
                }
            }
        }
    }
    
    private func loadModelVersions(workspace: String, project: String) {
        isLoadingVersions = true
        loadError = nil
        
        Task {
            do {
                let versions = try await ModelManager.shared.listModelVersions(workspace: workspace, project: project)
                await MainActor.run {
                    self.modelVersions = versions
                    self.isLoadingVersions = false
                    
                    if !versions.isEmpty && modelVersion.isEmpty {
                        self.modelVersion = versions.last?.id ?? ""
                    }
                }
            } catch {
                await MainActor.run {
                    self.isLoadingVersions = false
                    self.loadError = error.localizedDescription
                }
            }
        }
    }
    
    private func downloadModel() {
        guard !modelWorkspace.isEmpty, !modelProject.isEmpty, !modelVersion.isEmpty else {
            return
        }
        
        Task {
            do {
                try await ModelManager.shared.downloadModel(
                    workspace: modelWorkspace,
                    project: modelProject,
                    version: modelVersion
                )
            } catch {
                await MainActor.run {
                    loadError = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
