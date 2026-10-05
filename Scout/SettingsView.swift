import SwiftUI

// "Whose world is this? The world is yours" - Nas (probably)
// OAuth-based configuration for Roboflow

struct SettingsView: View {
    @AppStorage("scout_project") private var project: String = ""
    @AppStorage("scout_model_workspace") private var modelWorkspace: String = ""
    @AppStorage("scout_model_project") private var modelProject: String = ""
    @AppStorage("scout_model_version") private var modelVersion: String = ""
    @AppStorage("scout_confidence") private var confidence: Int = 40
    
    @ObservedObject var oauthManager = OAuthManager.shared
    @ObservedObject var modelManager = ModelManager.shared
    @State private var apiKey: String = ""  // Load from Keychain on appear
    @State private var isSigningIn = false
    @State private var signInError: String?
    @State private var workspaces: [Workspace] = []
    @State private var projects: [Project] = []
    @State private var selectedWorkspace: Workspace?
    @State private var previousWorkspace: Workspace?  // Track previous to detect real changes
    @State private var selectedModelProject: Project?
    @State private var previousModelProject: Project?  // Track previous to detect real changes
    @State private var modelVersions: [ModelVersion] = []
    @State private var isLoadingProjects = false
    @State private var isLoadingVersions = false
    @State private var loadError: String?
    @State private var loadGeneration = 0  // Track async load generation to ignore stale results
    
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
                            modelVersions = []
                            isLoadingProjects = false
                            isLoadingVersions = false
                            loadGeneration += 1  // Cancel in-flight loads
                            // Clear previous* BEFORE selected* to prevent isRealChange wipe
                            previousWorkspace = nil
                            previousModelProject = nil
                            selectedModelProject = nil
                            selectedWorkspace = nil
                            // Preserve API key upload project on sign out (API key path still needs it)
                            // Do NOT clear: project, modelProject, modelVersion, or currentModel (keep cached model for API key fallback)
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
                                    // Only clear state on real user-driven workspace change, not first populate
                                    let isRealChange = previousWorkspace != nil && previousWorkspace?.url != newWorkspace?.url
                                    
                                    if isRealChange {
                                        // Clear upload project, model project/version, and loaded model
                                        projects = []
                                        project = ""
                                        selectedModelProject = nil
                                        modelProject = ""
                                        modelVersion = ""
                                        modelVersions = []
                                        isLoadingVersions = false
                                        modelManager.currentModel = nil
                                        modelManager.currentVNCoreMLModel = nil
                                        modelManager.loadedWorkspace = nil
                                        modelManager.loadedProject = nil
                                        modelManager.loadedVersion = nil
                                    }
                                    
                                    previousWorkspace = newWorkspace
                                    
                                    if let workspace = newWorkspace {
                                        loadProjects(workspace: workspace.url)
                                    } else if isRealChange {
                                        // Only clear projects list if it's a real change to nil
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
                                // Only clear state on real project change, not first populate
                                let isRealChange = previousModelProject != nil && previousModelProject?.id != newProject?.id
                                
                                if let proj = newProject, let ws = selectedWorkspace {
                                    modelProject = proj.id
                                    modelWorkspace = ws.url
                                    
                                    // Only clear when project ID actually changes
                                    if isRealChange {
                                        modelVersion = ""
                                        modelManager.currentModel = nil
                                        modelManager.currentVNCoreMLModel = nil
                                    }
                                    
                                    loadModelVersions(workspace: ws.url, project: proj.id)
                                } else if isRealChange {
                                    // Deselecting project: clear versions and unload model (mirror non-nil clear)
                                    modelVersions = []
                                    modelVersion = ""
                                    modelProject = ""
                                    modelWorkspace = ""
                                    isLoadingVersions = false
                                    // Don't bump loadGeneration (races loadProjects and can stick isLoadingProjects)
                                    modelManager.currentModel = nil
                                    modelManager.currentVNCoreMLModel = nil
                                }
                                
                                previousModelProject = newProject
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
                            } else if !modelVersions.isEmpty && selectedModelProject != nil {
                                Picker("Model Version", selection: $modelVersion) {
                                    Text("Select version").tag("")
                                    ForEach(modelVersions) { version in
                                        Text(version.displayName).tag(version.id)
                                    }
                                }
                                .onChange(of: modelVersion) { newVersion in
                                    // Clear old model when version changes (prevents running stale model)
                                    let versionNum = newVersion.split(separator: "/").last.map(String.init) ?? newVersion
                                    if modelManager.currentModel != nil && modelManager.loadedVersion != versionNum {
                                        modelManager.currentModel = nil
                                        modelManager.currentVNCoreMLModel = nil
                                    }
                                }
                                
                                if !modelVersion.isEmpty && !modelWorkspace.isEmpty && !modelProject.isEmpty {
                                    // Check if the loaded model matches the selected version (strip to slugs)
                                    let projectSlug = modelProject.split(separator: "/").last.map(String.init) ?? modelProject
                                    let versionNum = modelVersion.split(separator: "/").last.map(String.init) ?? modelVersion
                                    let isModelReady = modelManager.currentModel != nil &&
                                        modelManager.loadedWorkspace == modelWorkspace &&
                                        modelManager.loadedProject == projectSlug &&
                                        modelManager.loadedVersion == versionNum
                                    
                                    if modelManager.isDownloading {
                                        HStack {
                                            ProgressView(value: modelManager.downloadProgress)
                                                .progressViewStyle(LinearProgressViewStyle())
                                            Text("\(Int(modelManager.downloadProgress * 100))%")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    } else if isModelReady {
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
                // Load API key from Keychain
                apiKey = KeychainHelper.loadAPIKey() ?? ""
                
                if oauthManager.isAuthenticated && workspaces.isEmpty {
                    loadWorkspacesAndProjects()
                }
                
                // Model is now auto-loaded at app startup by ModelManager.init
            }
            .onChange(of: apiKey) { newValue in
                // Save API key to Keychain (not plaintext UserDefaults)
                if newValue.isEmpty {
                    KeychainHelper.deleteAPIKey()
                } else {
                    KeychainHelper.saveAPIKey(newValue)
                }
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
        loadGeneration += 1
        let expectedGeneration = loadGeneration
        
        Task {
            do {
                let loadedWorkspaces = try await RoboflowService.shared.listWorkspaces()
                await MainActor.run {
                    // Ignore stale results from canceled/superseded load (e.g. after Sign Out)
                    guard self.loadGeneration == expectedGeneration,
                          self.oauthManager.isAuthenticated else { return }
                    
                    self.workspaces = loadedWorkspaces
                    
                    // Restore selectedWorkspace from AppStorage (modelWorkspace) if available
                    if !modelWorkspace.isEmpty,
                       let saved = loadedWorkspaces.first(where: { $0.url == modelWorkspace }) {
                        self.previousWorkspace = saved  // Set previous BEFORE selected to avoid onChange double-fetch
                        self.selectedWorkspace = saved
                        loadProjects(workspace: saved.url)
                    } else if let first = loadedWorkspaces.first {
                        self.previousWorkspace = first  // Set previous BEFORE selected to avoid onChange double-fetch
                        self.selectedWorkspace = first
                        loadProjects(workspace: first.url)
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.loadGeneration == expectedGeneration else { return }
                    loadError = error.localizedDescription
                }
            }
        }
    }
    
    private func loadProjects(workspace: String) {
        isLoadingProjects = true
        loadError = nil
        loadGeneration += 1
        let expectedGeneration = loadGeneration
        
        Task {
            do {
                let loadedProjects = try await RoboflowService.shared.listProjects(workspace: workspace)
                await MainActor.run {
                    // Ignore stale results from canceled/superseded load
                    guard self.loadGeneration == expectedGeneration else { return }
                    
                    // Check if picker was visible (SwiftUI doesn't fire onChange for starting value)
                    let pickerWasVisible = !self.projects.isEmpty
                    
                    self.projects = loadedProjects
                    self.isLoadingProjects = false
                    
                    // Restore upload project if empty
                    if !loadedProjects.isEmpty && project.isEmpty {
                        self.project = loadedProjects[0].id
                    }
                    
                    // Restore selectedModelProject from AppStorage (modelProject) if available
                    if !modelProject.isEmpty,
                       let saved = loadedProjects.first(where: { $0.id == modelProject }) {
                        let alreadySelected = self.selectedModelProject?.id == saved.id
                        self.previousModelProject = saved  // Set previous to avoid clearing on first switch
                        self.selectedModelProject = saved
                        // Call directly if onChange won't fire (unchanged selection or picker didn't exist)
                        if (alreadySelected || !pickerWasVisible) && !modelWorkspace.isEmpty {
                            loadModelVersions(workspace: modelWorkspace, project: saved.id)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    // Ignore stale errors from canceled/superseded load
                    guard self.loadGeneration == expectedGeneration else { return }
                    self.isLoadingProjects = false
                    self.loadError = error.localizedDescription
                }
            }
        }
    }
    
    private func loadModelVersions(workspace: String, project: String) {
        isLoadingVersions = true
        loadError = nil
        loadGeneration += 1
        let expectedGeneration = loadGeneration
        
        Task {
            do {
                let versions = try await ModelManager.shared.listModelVersions(workspace: workspace, project: project)
                await MainActor.run {
                    // Ignore stale results (don't touch flag - newer load owns it)
                    guard self.loadGeneration == expectedGeneration else { return }
                    
                    // Mismatched project (rapid A→B→A switches) - clear our flag
                    guard self.selectedModelProject?.id == project else {
                        self.isLoadingVersions = false
                        return
                    }
                    
                    self.modelVersions = versions
                    self.isLoadingVersions = false
                    
                    if !versions.isEmpty && modelVersion.isEmpty {
                        // Auto-select highest version number or latest created (not array position)
                        let selected = versions.max { a, b in
                            // Try numeric comparison of version numbers (id may be "workspace/project/N")
                            let aLastComponent = a.id.split(separator: "/").last.map(String.init) ?? a.id
                            let bLastComponent = b.id.split(separator: "/").last.map(String.init) ?? b.id
                            if let aNum = Int(aLastComponent), let bNum = Int(bLastComponent) {
                                return aNum < bNum
                            }
                            // Fallback: compare created timestamps (numeric or ISO string)
                            if let aCreated = a.created, let bCreated = b.created {
                                return aCreated < bCreated
                            }
                            // Default: keep first
                            return false
                        }
                        self.modelVersion = selected?.id ?? versions.first?.id ?? ""
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.loadGeneration == expectedGeneration else { return }
                    // Don't set error if project deselected (mirror success path project check)
                    guard self.selectedModelProject?.id == project else {
                        self.isLoadingVersions = false
                        return
                    }
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

// MARK: - Keychain Helper for API Key

struct KeychainHelper {
    private static let apiKeyKey = "scout_api_key"
    
    static func saveAPIKey(_ key: String) {
        let data = key.data(using: .utf8)!
        
        // Delete query: only class + account (no value)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: apiKeyKey
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        // Add query: class + account + value + accessibility
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: apiKeyKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }
    
    static func loadAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: apiKeyKey,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess,
           let data = result as? Data,
           let key = String(data: data, encoding: .utf8) {
            return key
        }
        
        // One-time migration: check UserDefaults for old API key
        if let oldKey = UserDefaults.standard.string(forKey: apiKeyKey), !oldKey.isEmpty {
            // Migrate to Keychain
            saveAPIKey(oldKey)
            // Remove from UserDefaults
            UserDefaults.standard.removeObject(forKey: apiKeyKey)
            return oldKey
        }
        
        return nil
    }
    
    static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: apiKeyKey
        ]
        SecItemDelete(query as CFDictionary)
    }
}

#Preview {
    SettingsView()
}
