import XCTest
import UIKit
@testable import Scout

final class NullUploadOrchestratorTests: XCTestCase {
    private var fixtureJPEG: Data!

    override func setUp() {
        super.setUp()
        // Draw a tiny bitmap to guarantee jpegData
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        fixtureJPEG = image.jpegData(compressionQuality: 0.9)
        XCTAssertNotNil(fixtureJPEG)
    }

    private func makeFrame(
        kept: Bool,
        reviewed: Bool,
        project: String,
        uploadedImageId: String? = nil
    ) -> CapturedFrame {
        CapturedFrame(
            detections: [],
            imageData: fixtureJPEG,
            kept: kept,
            reviewed: reviewed,
            uploadedImageId: uploadedImageId,
            imageWidth: 8,
            imageHeight: 8,
            modelProject: project,
            modelVersion: 1
        )
    }

    private func configuredClient(projects: [String]) -> MockRoboflowClient {
        let client = MockRoboflowClient()
        var byWs: [String: [Project]] = [:]
        for p in projects {
            let ws = String(p.split(separator: "/")[0])
            let slug = String(p.split(separator: "/")[1])
            byWs[ws, default: []].append(Project(id: p, name: slug, workspace: ws))
            client.batchIdByProject[p] = "batch-\(slug)"
        }
        client.projectsByWorkspace = byWs
        return client
    }

    func testExportKeptFrames_onlyReviewedKept() {
        let kept = makeFrame(kept: true, reviewed: true, project: "ws/proj")
        let discarded = makeFrame(kept: false, reviewed: true, project: "ws/proj")
        let unreviewed = makeFrame(kept: true, reviewed: false, project: "ws/proj")
        // Same predicate ExportSheet uses via FrameStorage.exportKeptFrames()
        let exported = [kept, discarded, unreviewed].filter { $0.reviewed && $0.kept }
        XCTAssertEqual(exported.map(\.id), [kept.id])
    }

    func testOnlyKeptFramesAreUploadedAndNullified() async {
        let project = "acme/sticks"
        let kept = makeFrame(kept: true, reviewed: true, project: project)
        let discarded = makeFrame(kept: false, reviewed: true, project: project)

        let client = configuredClient(projects: [project])
        let store = InMemoryFrameStore(frames: [kept, discarded])
        // ExportSheet receives exportKeptFrames(); mimic that filter
        let frames = [kept, discarded].filter { $0.reviewed && $0.kept }

        let orch = NullUploadOrchestrator(client: client, store: store)
        let result = await orch.runUploadAndNullify(
            frames: frames,
            selectedModelProject: "",
            batchName: "Scout - test"
        )

        XCTAssertEqual(client.zipCalls.count, 1)
        XCTAssertEqual(client.zipCalls[0].entries.map(\.frameId), [kept.id])
        XCTAssertEqual(client.annotateCalls.count, 1)
        XCTAssertEqual(client.annotateCalls[0].imageId.hasPrefix("img-"), true)
        XCTAssertFalse(client.zipCalls[0].entries.contains { $0.frameId == discarded.id })
        XCTAssertEqual(result.successCount, 1)
        XCTAssertTrue(result.nullifyFailures.isEmpty)
    }

    func testHappyPath_nullifiesAll_recordsBatchLink_noRetryList() async {
        let project = "acme/balls"
        let f1 = makeFrame(kept: true, reviewed: true, project: project)
        let f2 = makeFrame(kept: true, reviewed: true, project: project)
        let client = configuredClient(projects: [project])
        let store = InMemoryFrameStore(frames: [f1, f2])
        let orch = NullUploadOrchestrator(client: client, store: store)

        let result = await orch.runUploadAndNullify(
            frames: [f1, f2],
            selectedModelProject: "",
            batchName: "Scout - happy"
        )

        XCTAssertEqual(result.successCount, 2)
        XCTAssertEqual(result.failureCount, 0)
        XCTAssertTrue(result.nullifyFailures.isEmpty)
        XCTAssertEqual(client.annotateCalls.count, 2)
        XCTAssertEqual(result.uploadedBatches.count, 1)
        XCTAssertEqual(result.uploadedBatches[0].projectSlug, "balls")
        XCTAssertEqual(result.uploadedBatches[0].batchName, "Scout - happy")
        XCTAssertTrue(result.uploadedBatches[0].hasBatchId)
        XCTAssertEqual(store.frames.count, 0) // deleted on success
    }

    func testPartialNullifyFailure_landsInRetryList() async {
        let project = "acme/pucks"
        let f1 = makeFrame(kept: true, reviewed: true, project: project)
        let f2 = makeFrame(kept: true, reviewed: true, project: project)
        let client = configuredClient(projects: [project])
        let id1 = "img-\(f1.id.uuidString.prefix(8))"
        let id2 = "img-\(f2.id.uuidString.prefix(8))"
        client.uploadResultsByProject[project] = [f1.id: id1, f2.id: id2]
        client.failingNullifyImageIds = [id2]

        let store = InMemoryFrameStore(frames: [f1, f2])
        let orch = NullUploadOrchestrator(client: client, store: store)
        let result = await orch.runUploadAndNullify(
            frames: [f1, f2],
            selectedModelProject: "",
            batchName: "Scout - partial"
        )

        XCTAssertEqual(result.successCount, 1)
        XCTAssertEqual(result.nullifyFailures.count, 1)
        XCTAssertEqual(result.nullifyFailures[0].imageId, id2)
        XCTAssertEqual(result.nullifyFailures[0].frameId, f2.id)
        // successful frame deleted; failed remains
        XCTAssertEqual(store.frames.map(\.id), [f2.id])
    }

    func testRetryNullify_onlyFailedIds_clearsOnSuccess() async {
        let project = "acme/retry"
        let f1 = makeFrame(kept: true, reviewed: true, project: project)
        let client = configuredClient(projects: [project])
        let imageId = "img-retry-1"
        client.failingNullifyImageIds = [imageId] // fail first

        let store = InMemoryFrameStore(frames: [f1])
        let failure = NullifyFailure(
            frameId: f1.id,
            imageId: imageId,
            imageName: "scout_test_\(f1.id.uuidString.prefix(8)).jpg",
            imageWidth: 8,
            imageHeight: 8,
            project: project
        )

        let orch = NullUploadOrchestrator(client: client, store: store)
        let first = await orch.retryNullify(failures: [failure])
        XCTAssertEqual(first.remaining.count, 1)
        XCTAssertEqual(first.successCount, 0)
        XCTAssertEqual(client.annotateCalls.map(\.imageId), [imageId])

        client.failingNullifyImageIds = [] // succeed on retry
        let second = await orch.retryNullify(failures: first.remaining)
        XCTAssertTrue(second.remaining.isEmpty)
        XCTAssertEqual(second.successCount, 1)
        XCTAssertEqual(client.annotateCalls.count, 2)
        XCTAssertTrue(store.frames.isEmpty)
    }

    func testUploadFailure_noNullify_errorSurfaces() async {
        let project = "acme/fail"
        let f1 = makeFrame(kept: true, reviewed: true, project: project)
        let client = configuredClient(projects: [project])
        client.uploadShouldFail = true
        let store = InMemoryFrameStore(frames: [f1])
        let orch = NullUploadOrchestrator(client: client, store: store)

        let result = await orch.runUploadAndNullify(
            frames: [f1],
            selectedModelProject: "",
            batchName: "Scout - fail"
        )

        XCTAssertEqual(client.zipCalls.count, 1)
        XCTAssertEqual(client.annotateCalls.count, 0)
        XCTAssertEqual(result.failureCount, 1)
        XCTAssertEqual(result.successCount, 0)
        XCTAssertEqual(result.errorMessage, "Mock upload failed")
        XCTAssertTrue(result.uploadedBatches.isEmpty)
        XCTAssertEqual(store.frames.count, 1)
    }

    func testTwoProjects_twoBatchesAndLinks() async {
        let p1 = "acme/alpha"
        let p2 = "acme/beta"
        let f1 = makeFrame(kept: true, reviewed: true, project: p1)
        let f2 = makeFrame(kept: true, reviewed: true, project: p2)
        let client = configuredClient(projects: [p1, p2])
        let store = InMemoryFrameStore(frames: [f1, f2])
        let orch = NullUploadOrchestrator(client: client, store: store)

        let result = await orch.runUploadAndNullify(
            frames: [f1, f2],
            selectedModelProject: "",
            batchName: "Scout - multi"
        )

        XCTAssertEqual(client.zipCalls.count, 2)
        let projects = Set(client.zipCalls.map(\.project))
        XCTAssertEqual(projects, [p1, p2])
        XCTAssertEqual(result.uploadedBatches.count, 2)
        XCTAssertEqual(Set(result.uploadedBatches.map(\.projectSlug)), ["alpha", "beta"])
        XCTAssertEqual(result.successCount, 2)
        XCTAssertEqual(client.annotateCalls.count, 2)
    }

    func testNullCOCOFileNameMatchesScoutFilename() async {
        let project = "acme/coco"
        let frame = makeFrame(kept: true, reviewed: true, project: project)
        let client = configuredClient(projects: [project])
        let store = InMemoryFrameStore(frames: [frame])
        let orch = NullUploadOrchestrator(client: client, store: store)

        _ = await orch.runUploadAndNullify(
            frames: [frame],
            selectedModelProject: "",
            batchName: "Scout - coco"
        )

        XCTAssertEqual(client.zipCalls.count, 1)
        XCTAssertEqual(client.annotateCalls.count, 1)
        let uploadedName = client.zipCalls[0].entries[0].imageName
        let annotateName = client.annotateCalls[0].imageName
        XCTAssertEqual(uploadedName, annotateName)
        XCTAssertTrue(uploadedName.hasPrefix("scout_"))
        XCTAssertTrue(uploadedName.hasSuffix(".jpg"))

        let coco = RoboflowService.makeNullAnnotationCOCO(
            imageName: uploadedName,
            imageWidth: 8,
            imageHeight: 8
        )
        let images = coco["images"] as? [[String: Any]]
        XCTAssertEqual(images?.first?["file_name"] as? String, uploadedName)
    }
}
