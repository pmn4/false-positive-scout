import SwiftUI

// "Sleep is the cousin of death, so I'm wide awake" ~Nas (probably)
// Model picker for Scout camera screen

struct ModelPickerSheet: View {
    @ObservedObject var modelManager: ModelManager
    @ObservedObject var oauthManager: OAuthManager
    @Binding var isPresented: Bool
    
    @AppStorage("scout_model_workspace") private var modelWorkspace: String = ""
    @AppStorage("scout_model_project") private var modelProject: String = ""
    @AppStorage("scout_model_version") private var modelVersion: String = ""
    
    @State private var workspaces: [Workspace] = []
    @State private var projects: [Project] = []
    @State private var versions: [ModelVersion] = []
    @State private var selectedWorkspace: Workspace?
    @State private var selectedProject: Project?
    @State private var isLoadingWorkspaces = false
    @State private var isLoadingProjects = false
    @State private var isLoadingVersions = false
    @State private var errorMessage: String?
    @State private var apiKey: String = ""
    
    var body: some View {
        NavigationView {
            Form {
                CurrentModelSection(modelManager: modelManager)
                
                if !apiKey.isEmpty || oauthManager.isAuthenticated {
                    WorkspaceProjectSection(
                        workspaces: $workspaces,
                        projects: $projects,
                        selectedWorkspace: $selectedWorkspace,
                        selectedProject: $selectedProject,
                        isLoadingWorkspaces: $isLoadingWorkspaces,
                        isLoadingProjects: $isLoadingProjects,
                        onWorkspaceChange: loadProjects,
                        onProjectChange: loadModelVersions
                    )
                    
                    VersionSection(
                        versions: $versions,
                        selectedVersion: $modelVersion,
                        isLoadingVersions: $isLoadingVersions,
                        modelManager: modelManager,
                        modelWorkspace: $modelWorkspace,
                        modelProject: $modelProject,
                        onDownload: downloadModel
                    )
                } else {
                    Section {
                        Text("Configure an API key or sign in with OAuth in Settings to load models")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Select Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
            .onAppear {
                apiKey = KeychainHelper.loadAPIKey() ?? ""
                if !apiKey.isEmpty || oauthManager.isAuthenticated {
                    loadInitialData()
                }
            }
        }
    }
    
    private func loadInitialData() {
        isLoadingWorkspaces = true
        errorMessage = nil
        
        Task {
            do {
                let key = oauthManager.isAuthenticated ? nil : apiKey
                let loadedWorkspaces = try await RoboflowService.shared.listWorkspaces(apiKey: key)
                
                await MainActor.run {
                    self.workspaces = loadedWorkspaces
                    self.isLoadingWorkspaces = false
                    
                    if !modelWorkspace.isEmpty,
                       let saved = loadedWorkspaces.first(where: { $0.url == modelWorkspace }) {
                        self.selectedWorkspace = saved
                        loadProjects(workspace: saved.url)
                    } else if let first = loadedWorkspaces.first {
                        self.selectedWorkspace = first
                        loadProjects(workspace: first.url)
                    }
                }
            } catch {
                await MainActor.run {
                    self.isLoadingWorkspaces = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private func loadProjects(workspace: String) {
        isLoadingProjects = true
        errorMessage = nil
        
        Task {
            do {
                let key = oauthManager.isAuthenticated ? nil : apiKey
                let loadedProjects = try await RoboflowService.shared.listProjects(workspace: workspace, apiKey: key)
                
                await MainActor.run {
                    self.projects = loadedProjects
                    self.isLoadingProjects = false
                    
                    if !modelProject.isEmpty,
                       let saved = loadedProjects.first(where: { $0.id == modelProject }) {
                        self.selectedProject = saved
                        loadModelVersions(project: saved.id)
                    }
                }
            } catch {
                await MainActor.run {
                    self.isLoadingProjects = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private func loadModelVersions(project: String) {
        guard let workspace = selectedWorkspace?.url else { return }
        
        isLoadingVersions = true
        errorMessage = nil
        
        Task {
            do {
                let key = oauthManager.isAuthenticated ? nil : apiKey
                let loadedVersions = try await ModelManager.shared.listModelVersions(
                    workspace: workspace,
                    project: project,
                    apiKey: key
                )
                
                await MainActor.run {
                    self.versions = loadedVersions
                    self.isLoadingVersions = false
                }
            } catch {
                await MainActor.run {
                    self.isLoadingVersions = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private func downloadModel() {
        guard let workspace = selectedWorkspace?.url,
              let project = selectedProject?.id,
              !modelVersion.isEmpty else {
            return
        }
        
        modelWorkspace = workspace
        modelProject = project
        
        Task {
            do {
                let key = oauthManager.isAuthenticated ? nil : apiKey
                try await ModelManager.shared.downloadModel(
                    workspace: workspace,
                    project: project,
                    version: modelVersion,
                    apiKey: key
                )
                await MainActor.run {
                    errorMessage = nil
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct CurrentModelSection: View {
    @ObservedObject var modelManager: ModelManager
    
    var body: some View {
        Section {
            if let workspace = modelManager.loadedWorkspace,
               let project = modelManager.loadedProject,
               let version = modelManager.loadedVersion {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Current Model")
                            .font(.headline)
                    }
                    Text("\(workspace)/\(project)/\(version)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !modelManager.classLabels.isEmpty {
                        Text("\(modelManager.classLabels.count) classes")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } else {
                Text("No model loaded")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct WorkspaceProjectSection: View {
    @Binding var workspaces: [Workspace]
    @Binding var projects: [Project]
    @Binding var selectedWorkspace: Workspace?
    @Binding var selectedProject: Project?
    @Binding var isLoadingWorkspaces: Bool
    @Binding var isLoadingProjects: Bool
    let onWorkspaceChange: (String) -> Void
    let onProjectChange: (String) -> Void
    
    var body: some View {
        Section {
            if isLoadingWorkspaces {
                HStack {
                    ProgressView()
                    Text("Loading workspaces...")
                        .font(.caption)
                }
            } else if !workspaces.isEmpty {
                Picker("Workspace", selection: $selectedWorkspace) {
                    Text("Select workspace").tag(nil as Workspace?)
                    ForEach(workspaces) { workspace in
                        Text(workspace.name).tag(workspace as Workspace?)
                    }
                }
                .onChange(of: selectedWorkspace) { newValue in
                    if let workspace = newValue {
                        onWorkspaceChange(workspace.url)
                    }
                }
            }
            
            if isLoadingProjects {
                HStack {
                    ProgressView()
                    Text("Loading projects...")
                        .font(.caption)
                }
            } else if !projects.isEmpty {
                Picker("Project", selection: $selectedProject) {
                    Text("Select project").tag(nil as Project?)
                    ForEach(projects) { project in
                        Text(project.name).tag(project as Project?)
                    }
                }
                .onChange(of: selectedProject) { newValue in
                    if let project = newValue {
                        onProjectChange(project.id)
                    }
                }
            }
        } header: {
            Text("Select Model")
        }
    }
}

struct VersionSection: View {
    @Binding var versions: [ModelVersion]
    @Binding var selectedVersion: String
    @Binding var isLoadingVersions: Bool
    @ObservedObject var modelManager: ModelManager
    @Binding var modelWorkspace: String
    @Binding var modelProject: String
    let onDownload: () -> Void
    
    @State private var lastError: String?
    
    var body: some View {
        Section {
            if isLoadingVersions {
                HStack {
                    ProgressView()
                    Text("Loading versions...")
                        .font(.caption)
                }
            } else if versions.isEmpty {
                EmptyVersionsState()
            } else {
                Picker("Version", selection: $selectedVersion) {
                    Text("Select version").tag("")
                    ForEach(versions) { version in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(version.displayName)
                                Spacer()
                                if isVersionCached(version) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.caption)
                                }
                            }
                            if let detail = version.detailText {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .tag(version.id)
                    }
                }
                
                if !selectedVersion.isEmpty {
                    VersionStatusView(
                        selectedVersion: selectedVersion,
                        modelManager: modelManager,
                        modelWorkspace: modelWorkspace,
                        modelProject: modelProject,
                        isCached: isVersionCached(versions.first { $0.id == selectedVersion }),
                        lastError: $lastError,
                        onDownload: {
                            lastError = nil
                            onDownload()
                        }
                    )
                }
            }
        } header: {
            Text("Version")
        }
    }
    
    private func isVersionCached(_ version: ModelVersion?) -> Bool {
        guard let version = version else { return false }
        return modelManager.isModelCached(
            workspace: modelWorkspace,
            project: modelProject,
            version: version.id
        )
    }
}

struct EmptyVersionsState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On-Device Inference")
                .font(.headline)
            Text("Models run directly on your device after a one-time download. No internet required during scanning.")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Select a project above to see available model versions.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct VersionStatusView: View {
    let selectedVersion: String
    @ObservedObject var modelManager: ModelManager
    let modelWorkspace: String
    let modelProject: String
    let isCached: Bool
    @Binding var lastError: String?
    let onDownload: () -> Void
    
    private var isCurrentModel: Bool {
        let projectSlug = modelProject.split(separator: "/").last.map(String.init) ?? modelProject
        let versionNum = selectedVersion.split(separator: "/").last.map(String.init) ?? selectedVersion
        return modelManager.currentModel != nil &&
            modelManager.loadedWorkspace == modelWorkspace &&
            modelManager.loadedProject == projectSlug &&
            modelManager.loadedVersion == versionNum
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if modelManager.isDownloading {
                DownloadProgressView(
                    stage: modelManager.downloadStage,
                    progress: modelManager.downloadProgress
                )
            } else if let error = lastError {
                ErrorView(error: error, onRetry: {
                    lastError = nil
                    onDownload()
                })
            } else if isCurrentModel {
                ReadyView()
            } else if isCached {
                CachedModelView(onLoad: onDownload)
            } else {
                DownloadButton(onDownload: onDownload)
            }
        }
        .padding(.vertical, 4)
    }
}

struct DownloadProgressView: View {
    let stage: String
    let progress: Double
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text(stage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if progress > 0 {
                ProgressView(value: progress) {
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Text("Your current model will keep running until the new one is ready")
                .font(.caption2)
                .foregroundColor(.secondary)
                .italic()
        }
    }
}

struct ErrorView: View {
    let error: String
    let onRetry: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text("Error")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.red)
            }
            
            Text(error)
                .font(.caption2)
                .foregroundColor(.secondary)
            
            Button(action: onRetry) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry")
                }
                .font(.caption)
            }
        }
    }
}

struct ReadyView: View {
    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text("Ready - This model is currently running")
                .font(.caption)
                .foregroundColor(.green)
        }
    }
}

struct CachedModelView: View {
    let onLoad: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(.blue)
                Text("Downloaded")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
            
            Button("Load Model") {
                onLoad()
            }
            .font(.caption)
        }
    }
}

struct DownloadButton: View {
    let onDownload: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onDownload) {
                HStack {
                    Image(systemName: "arrow.down.circle")
                    Text("Download & Load Model")
                }
                .font(.caption)
            }
            
            Text("One-time download. Runs offline after that.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    ModelPickerSheet(
        modelManager: ModelManager.shared,
        oauthManager: OAuthManager.shared,
        isPresented: .constant(true)
    )
}
