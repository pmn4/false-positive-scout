import Foundation

/// Seam used by upload/nullify orchestration and by `RoboflowService` zip composition.
/// High-level methods power ExportSheet; fine-grained zip steps are the building blocks.
protocol RoboflowUploading: AnyObject {
    func listProjects(workspace: String) async throws -> [Project]

    func uploadImagesViaZip(
        entries: [ZipUploadEntry],
        project: String,
        batchName: String,
        tags: [String],
        onProgress: (@MainActor (String) -> Void)?
    ) async throws -> ZipUploadResult

    func annotateAsNull(
        imageId: String,
        imageName: String,
        imageWidth: Int,
        imageHeight: Int,
        project: String
    ) async throws

    // Fine-grained zip / batch steps (implemented by RoboflowService).
    func initiateZipUpload(
        workspace: String,
        projectSlug: String,
        batchName: String,
        tags: [String]
    ) async throws -> (taskId: String, signedUrl: URL)

    func putSignedZip(signedUrl: URL, zipData: Data) async throws

    func pollZipTask(workspace: String, taskId: String) async throws -> [String: Any]

    func resolveImageId(
        workspace: String,
        projectSlug: String,
        filename: String
    ) async throws -> String

    func resolveBatchId(
        workspace: String,
        projectSlug: String,
        batchName: String,
        pollJSON: [String: Any]
    ) async -> String?
}

/// Storage side-effects during upload/nullify (mark uploaded, delete on success).
protocol FrameUploadStore: AnyObject {
    var frames: [CapturedFrame] { get }
    func markUploaded(_ frame: CapturedFrame, imageId: String)
    func deleteFrame(_ frame: CapturedFrame)
}

extension FrameStorage: FrameUploadStore {}

/// One image that uploaded but failed nullify (retry list entry).
struct NullifyFailure: Equatable, Identifiable {
    var id: UUID { frameId }
    let frameId: UUID
    let imageId: String
    let imageName: String
    let imageWidth: Int
    let imageHeight: Int
    let project: String
}

/// Outcome of a full upload+nullify run (or retry).
struct NullUploadRunResult: Equatable {
    var successCount: Int = 0
    var failureCount: Int = 0
    var nullifyFailures: [NullifyFailure] = []
    var uploadedBatches: [UploadedBatchLink] = []
    var errorMessage: String?
}
