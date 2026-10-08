import SwiftUI
import Security

// "Whose world is this? The world is yours" - Nas (probably)
// OAuth-based configuration for Roboflow

struct SettingsView: View {
    @AppStorage("scout_upload_project") private var project: String = ""
    @AppStorage("scout_model_workspace") private var modelWorkspace: String = ""
    @AppStorage("scout_model_project") private var modelProject: String = ""
    @AppStorage("scout_model_version") private var modelVersion: String = ""
    
    @ObservedObject var oauthManager = OAuthManager.shared
    @ObservedObject var modelManager = ModelManager.shared
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
    
    private var authStatus: String {
        if oauthManager.isAuthenticated {
            return "Signed In"
        }
        return "Not Signed In"
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Log in with Roboflow to download models and upload null frames. Tokens stay in Keychain on this device.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        HStack {
                            Text("Status:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(authStatus)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(oauthManager.isAuthenticated ? .green : .red)
                        }
                        if oauthManager.isAuthenticated, let ws = oauthManager.workspaceURL, !ws.isEmpty {
                            Text("Workspace: \(ws)")
                                .font(.caption)
                                .foregroundColor(.secondary)
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
                            Task {
                                await oauthManager.signOut()
                                workspaces = []
                                projects = []
                                modelVersions = []
                                isLoadingProjects = false
                                isLoadingVersions = false
                                loadGeneration += 1
                                previousWorkspace = nil
                                previousModelProject = nil
                                selectedModelProject = nil
                                selectedWorkspace = nil
                            }
                        }) {
                            HStack {
                                Spacer()
                                Text("Log out")
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
                                Text(isSigningIn ? "Logging in..." : "Log in with Roboflow")
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
                    Text("Account")
                } footer: {
                    Text("Uses OAuth PKCE (public client, no secret). Access tokens last ~24h and refresh automatically.")
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
                                    // Detect selection changes: previous?.url != new?.url (includes nil→value, value→different, value→nil)
                                    let urlChanged = previousWorkspace?.url != newWorkspace?.url
                                    // Real change: previous was non-nil (user switching, not first populate/restore)
                                    let isRealChange = previousWorkspace != nil && urlChanged
                                    
                                    if isRealChange {
                                        // Clear upload project, model project/version, and loaded model (only on real user-driven change)
                                        projects = []
                                        project = ""
                                        previousModelProject = nil  // Clear before selectedModelProject to avoid stale previous
                                        selectedModelProject = nil
                                        modelProject = ""
                                        modelWorkspace = ""  // Clear with modelProject to prevent wrong restore
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
                                    
                                    // Fetch on any ID change (nil→value, value→different, value→nil), not on no-op restore
                                    if urlChanged {
                                        if let workspace = newWorkspace {
                                            loadProjects(workspace: workspace.url)
                                        } else {
                                            // Clear projects list on deselect and cancel in-flight fetch
                                            loadGeneration += 1
                                            isLoadingProjects = false
                                            projects = []
                                            project = ""
                                        }
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
                                // Detect selection changes: previous?.id != new?.id (includes nil→value, value→different, value→nil)
                                let idChanged = previousModelProject?.id != newProject?.id
                                // Real change: previous was non-nil (user switching, not first populate/restore)
                                let isRealChange = previousModelProject != nil && idChanged
                                
                                if let proj = newProject, let ws = selectedWorkspace {
                                    modelProject = proj.id
                                    modelWorkspace = ws.url
                                    
                                    // Clear model state and fetch whenever project ID changes (nil→value, value→different)
                                    if idChanged {
                                        modelVersion = ""
                                        modelManager.currentModel = nil
                                        modelManager.currentVNCoreMLModel = nil
                                        loadModelVersions(workspace: ws.url, project: proj.id)
                                    }
                                } else if idChanged {
                                    // Deselecting project or clearing: clear versions and unload model
                                    modelVersions = []
                                    modelVersion = ""
                                    modelProject = ""
                                    modelWorkspace = ""
                                    isLoadingVersions = false
                                    // Don't bump loadGeneration (races loadProjects and can stick isLoadingProjects)
                                    if isRealChange {
                                        modelManager.currentModel = nil
                                        modelManager.currentVNCoreMLModel = nil
                                    }
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
            .onChange(of: oauthManager.isAuthenticated) { isAuth in
                // Reset state when OAuthManager self-signOut (refresh 400/401) flips isAuthenticated
                if !isAuth {
                    // Clear only ephemeral OAuth-populated @State (not AppStorage or cached model)
                    workspaces = []
                    projects = []
                    modelVersions = []
                    isLoadingProjects = false
                    isLoadingVersions = false
                    loadError = nil
                    loadGeneration += 1  // Cancel in-flight loads
                    // Clear previous* BEFORE selected* to prevent isRealChange wipe
                    previousWorkspace = nil
                    previousModelProject = nil
                    selectedModelProject = nil
                    selectedWorkspace = nil
                }
            }
            .onAppear {
                if modelWorkspace.isEmpty, let ws = Secrets.roboflowWorkspace {
                    modelWorkspace = ws
                }
                if modelProject.isEmpty, let proj = Secrets.roboflowProject {
                    // Prefer full workspace/project id when workspace known
                    if proj.contains("/") {
                        modelProject = proj
                    } else if !modelWorkspace.isEmpty {
                        modelProject = "\(modelWorkspace)/\(proj)"
                    } else {
                        modelProject = proj
                    }
                }
                
                if oauthManager.isAuthenticated && workspaces.isEmpty {
                    loadWorkspacesAndProjects()
                }

                // Model is now auto-loaded at app startup by ModelManager.init
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

// MARK: - Legacy Keychain cleanup

struct KeychainHelper {
    /// Legacy Keychain account from the removed paste-credential auth path.
    private static let apiKeyKey = "scout_api_key"

    /// Delete leftover credential from earlier Scout builds (called once on upgrade).
    static func deleteAPIKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: apiKeyKey
        ]
        SecItemDelete(query as CFDictionary)
        UserDefaults.standard.removeObject(forKey: apiKeyKey)
    }
}
