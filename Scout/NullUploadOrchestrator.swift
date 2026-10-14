import Foundation
import UIKit

/// Testable upload → nullify → retry orchestration (logic extracted from ExportSheet).
final class NullUploadOrchestrator {
    private let client: RoboflowUploading
    private let store: FrameUploadStore

    init(client: RoboflowUploading, store: FrameUploadStore) {
        self.client = client
        self.store = store
    }

    private static let scoutFilenameDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    static func makeScoutImageName(frameId: UUID, date: Date = Date()) -> String {
        let stamp = scoutFilenameDateFormatter.string(from: date)
        let shortId = String(frameId.uuidString.prefix(8)).lowercased()
        return "scout_\(stamp)_\(shortId).jpg"
    }

    static func makeBatchName(date: Date = Date()) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Scout - \(dateFormatter.string(from: date))"
    }

    private func projectSlug(_ projectId: String) -> String {
        projectId.split(separator: "/").last.map(String.init) ?? projectId
    }

    private func workspaceSlug(from projectId: String) -> String? {
        guard projectId.contains("/") else { return nil }
        return String(projectId.split(separator: "/").first!)
    }

    private func projectsContain(_ list: [Project], projectId: String) -> Bool {
        let slug = projectSlug(projectId)
        return list.contains { project in
            project.id == projectId || project.id == slug || project.id.hasSuffix("/\(slug)")
        }
    }

    private func targetProject(for frame: CapturedFrame, selectedModelProject: String) -> String? {
        if let project = frame.modelProject, !project.isEmpty {
            return project
        }
        if !selectedModelProject.isEmpty {
            return selectedModelProject
        }
        return nil
    }

    /// Upload kept frames (caller should pass `exportKeptFrames()`), nullify, record batch links.
    func runUploadAndNullify(
        frames: [CapturedFrame],
        selectedModelProject: String,
        batchName: String? = nil,
        onProgress: (@MainActor (UploadProgress) -> Void)? = nil
    ) async -> NullUploadRunResult {
        var result = NullUploadRunResult()
        let batch = batchName ?? Self.makeBatchName()

        var projectsByWorkspace: [String: [Project]] = [:]
        var needUploadByProject: [String: [(frame: CapturedFrame, imageName: String, width: Int, height: Int, jpeg: Data)]] = [:]
        var nullifyOnly: [(frame: CapturedFrame, imageName: String, imageId: String, width: Int, height: Int, project: String)] = []

        for frame in frames {
            guard let imageData = frame.imageData,
                  let image = UIImage(data: imageData),
                  let jpeg = image.jpegData(compressionQuality: 0.8) else {
                result.failureCount += 1
                result.errorMessage = "Frame missing image data"
                continue
            }

            let width = frame.imageWidth ?? Int(image.size.width)
            let height = frame.imageHeight ?? Int(image.size.height)

            guard let project = targetProject(for: frame, selectedModelProject: selectedModelProject) else {
                result.failureCount += 1
                result.errorMessage = "Frame has no model project. Re-capture with a model loaded, or select a model in Settings for legacy frames."
                continue
            }

            guard let workspace = workspaceSlug(from: project) else {
                result.failureCount += 1
                result.errorMessage = "Project \"\(project)\" is missing a workspace prefix (expected workspace/project)."
                continue
            }

            do {
                let projects: [Project]
                if let cached = projectsByWorkspace[workspace] {
                    projects = cached
                } else {
                    let loaded = try await client.listProjects(workspace: workspace)
                    projectsByWorkspace[workspace] = loaded
                    projects = loaded
                }
                guard projectsContain(projects, projectId: project) else {
                    result.failureCount += 1
                    result.errorMessage = "Project \"\(project)\" is not in your Roboflow workspace. Skipping frame."
                    continue
                }
            } catch {
                result.failureCount += 1
                result.errorMessage = "Could not verify project \"\(project)\": \(error.localizedDescription)"
                continue
            }

            let imageName = Self.makeScoutImageName(frameId: frame.id)

            if let existingImageId = frame.uploadedImageId, !existingImageId.isEmpty {
                nullifyOnly.append((frame, imageName, existingImageId, width, height, project))
            } else {
                needUploadByProject[project, default: []].append((frame, imageName, width, height, jpeg))
            }
        }

        let totalFrames = frames.count
        var completed = 0

        for (project, group) in needUploadByProject {
            await onProgress?(UploadProgress(
                current: completed,
                total: totalFrames,
                currentImageName: projectSlug(project),
                stage: "Preparing zip for \(projectSlug(project))…"
            ))

            let entries = group.map {
                ZipUploadEntry(frameId: $0.frame.id, imageName: $0.imageName, jpegData: $0.jpeg)
            }
            guard !entries.isEmpty else { continue }

            do {
                let zipResult = try await client.uploadImagesViaZip(
                    entries: entries,
                    project: project,
                    batchName: batch,
                    tags: [RoboflowService.defaultUploadTag],
                    onProgress: { stage in
                        onProgress?(UploadProgress(
                            current: completed,
                            total: totalFrames,
                            currentImageName: "\(self.projectSlug(project)) · \(entries.count) images",
                            stage: stage
                        ))
                    }
                )

                let linkId = zipResult.batchId ?? "project:\(zipResult.projectSlug)"
                result.uploadedBatches.append(UploadedBatchLink(
                    id: linkId,
                    projectSlug: zipResult.projectSlug,
                    batchName: zipResult.batchName,
                    url: zipResult.openURL,
                    hasBatchId: zipResult.batchId != nil
                ))

                for item in group {
                    guard let imageId = zipResult.imageIds[item.frame.id] else {
                        result.failureCount += 1
                        result.errorMessage = "No image id resolved for \(item.imageName)"
                        continue
                    }
                    await MainActor.run {
                        store.markUploaded(item.frame, imageId: imageId)
                    }
                    nullifyOnly.append((item.frame, item.imageName, imageId, item.width, item.height, project))
                }
            } catch {
                result.failureCount += group.count
                result.errorMessage = error.localizedDescription
            }
        }

        let toNullify = nullifyOnly
        for (index, item) in toNullify.enumerated() {
            await onProgress?(UploadProgress(
                current: index + 1,
                total: max(toNullify.count, 1),
                currentImageName: item.imageName,
                stage: "Nullifying \(index + 1)/\(toNullify.count)…"
            ))

            do {
                try await client.annotateAsNull(
                    imageId: item.imageId,
                    imageName: item.imageName,
                    imageWidth: item.width,
                    imageHeight: item.height,
                    project: item.project
                )
                result.successCount += 1
                await MainActor.run {
                    store.deleteFrame(item.frame)
                }
                completed += 1
            } catch {
                result.nullifyFailures.append(NullifyFailure(
                    frameId: item.frame.id,
                    imageId: item.imageId,
                    imageName: item.imageName,
                    imageWidth: item.width,
                    imageHeight: item.height,
                    project: item.project
                ))
                result.errorMessage = error.localizedDescription
            }
        }

        return result
    }

    /// Retry nullify for previous failures; returns remaining failures + how many succeeded.
    func retryNullify(
        failures: [NullifyFailure]
    ) async -> (remaining: [NullifyFailure], successCount: Int, errorMessage: String?) {
        var remaining: [NullifyFailure] = []
        var successCount = 0
        var errorMessage: String?

        for failure in failures {
            do {
                try await client.annotateAsNull(
                    imageId: failure.imageId,
                    imageName: failure.imageName,
                    imageWidth: failure.imageWidth,
                    imageHeight: failure.imageHeight,
                    project: failure.project
                )
                successCount += 1
                await MainActor.run {
                    if let frame = store.frames.first(where: { $0.id == failure.frameId }) {
                        store.deleteFrame(frame)
                    }
                }
            } catch {
                remaining.append(failure)
                errorMessage = error.localizedDescription
            }
        }

        return (remaining, successCount, errorMessage)
    }
}
