import Foundation
@testable import Scout

enum MockRoboflowError: Error, LocalizedError {
    case uploadFailed
    case nullifyFailed(imageId: String)
    case generic(String)

    var errorDescription: String? {
        switch self {
        case .uploadFailed: return "Mock upload failed"
        case .nullifyFailed(let id): return "Mock nullify failed for \(id)"
        case .generic(let s): return s
        }
    }
}

/// In-memory frame store for tests (no disk / UserDefaults).
final class InMemoryFrameStore: FrameUploadStore {
    var frames: [CapturedFrame]

    init(frames: [CapturedFrame] = []) {
        self.frames = frames
    }

    func markUploaded(_ frame: CapturedFrame, imageId: String) {
        if let i = frames.firstIndex(where: { $0.id == frame.id }) {
            frames[i].uploadedImageId = imageId
        }
    }

    func deleteFrame(_ frame: CapturedFrame) {
        frames.removeAll { $0.id == frame.id }
    }
}

/// Records Roboflow calls; configurable per-test behavior.
final class MockRoboflowClient: RoboflowUploading {
    struct ZipCall {
        let entries: [ZipUploadEntry]
        let project: String
        let batchName: String
        let tags: [String]
    }

    struct AnnotateCall {
        let imageId: String
        let imageName: String
        let imageWidth: Int
        let imageHeight: Int
        let project: String
    }

    var zipCalls: [ZipCall] = []
    var annotateCalls: [AnnotateCall] = []
    var listProjectsCalls: [String] = []

    /// workspace -> projects
    var projectsByWorkspace: [String: [Project]] = [:]

    /// project -> (frameId -> imageId) returned from zip upload
    var uploadResultsByProject: [String: [UUID: String]] = [:]
    var batchIdByProject: [String: String] = [:]

    /// When true, zip upload throws for that project (or all if empty set matches any)
    var failingUploadProjects: Set<String> = []
    var uploadShouldFail = false

    /// Image IDs that fail annotateAsNull
    var failingNullifyImageIds: Set<String> = []

    // Fine-grained recording (optional; high-level path used by orchestrator)
    var initiateZipCalls = 0
    var putSignedZipCalls = 0
    var pollZipCalls = 0
    var resolveImageIdCalls = 0
    var resolveBatchIdCalls = 0

    func listProjects(workspace: String) async throws -> [Project] {
        listProjectsCalls.append(workspace)
        return projectsByWorkspace[workspace] ?? []
    }

    func uploadImagesViaZip(
        entries: [ZipUploadEntry],
        project: String,
        batchName: String,
        tags: [String],
        onProgress: (@MainActor (String) -> Void)?
    ) async throws -> ZipUploadResult {
        zipCalls.append(ZipCall(entries: entries, project: project, batchName: batchName, tags: tags))
        await onProgress?("mock-upload")

        if uploadShouldFail || failingUploadProjects.contains(project) {
            throw MockRoboflowError.uploadFailed
        }

        let slug = project.split(separator: "/").last.map(String.init) ?? project
        let ws = project.split(separator: "/").first.map(String.init) ?? "ws"
        let ids = uploadResultsByProject[project] ?? Dictionary(
            uniqueKeysWithValues: entries.map { ($0.frameId, "img-\($0.frameId.uuidString.prefix(8))") }
        )
        let batchId = batchIdByProject[project]
        return ZipUploadResult(
            imageIds: ids,
            batchId: batchId,
            openURL: RoboflowService.annotateURL(workspace: ws, projectSlug: slug, batchId: batchId),
            batchName: batchName,
            workspace: ws,
            projectSlug: slug
        )
    }

    func annotateAsNull(
        imageId: String,
        imageName: String,
        imageWidth: Int,
        imageHeight: Int,
        project: String
    ) async throws {
        annotateCalls.append(AnnotateCall(
            imageId: imageId,
            imageName: imageName,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            project: project
        ))
        if failingNullifyImageIds.contains(imageId) {
            throw MockRoboflowError.nullifyFailed(imageId: imageId)
        }
    }

    func initiateZipUpload(
        workspace: String,
        projectSlug: String,
        batchName: String,
        tags: [String]
    ) async throws -> (taskId: String, signedUrl: URL) {
        initiateZipCalls += 1
        return ("task", URL(string: "https://example.com/signed")!)
    }

    func putSignedZip(signedUrl: URL, zipData: Data) async throws {
        putSignedZipCalls += 1
    }

    func pollZipTask(workspace: String, taskId: String) async throws -> [String: Any] {
        pollZipCalls += 1
        return ["status": "completed"]
    }

    func resolveImageId(
        workspace: String,
        projectSlug: String,
        filename: String
    ) async throws -> String {
        resolveImageIdCalls += 1
        return "resolved-\(filename)"
    }

    func resolveBatchId(
        workspace: String,
        projectSlug: String,
        batchName: String,
        pollJSON: [String: Any]
    ) async -> String? {
        resolveBatchIdCalls += 1
        return batchIdByProject["\(workspace)/\(projectSlug)"]
    }
}
