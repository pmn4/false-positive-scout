import Foundation
import UIKit

// "I never sleep, 'cause sleep is the cousin of death" - Nas (probably)
// Service for Roboflow REST (Bearer OAuth only)

// "Upload progress like I'm on a mission" ~Nas (probably)
struct UploadProgress {
    var current: Int
    var total: Int
    var currentImageName: String
    var stage: String

    var percentage: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }

    init(current: Int, total: Int, currentImageName: String, stage: String = "") {
        self.current = current
        self.total = total
        self.currentImageName = currentImageName
        self.stage = stage
    }
}

// "Born alone, die alone, no crew to keep my crown" ~Nas (probably)
struct Workspace: Codable, Identifiable, Hashable {
    let url: String
    let name: String
    let members: Int?

    var id: String { url }
}

struct Project: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let workspace: String?
}

/// One JPEG entry destined for a zip upload batch.
struct ZipUploadEntry {
    let frameId: UUID
    let imageName: String
    let jpegData: Data
}

struct ZipUploadResult {
    let imageIds: [UUID: String]
    let batchId: String?
    /// Confirmed app.roboflow.com link (batch page when id known, else project Annotate).
    let openURL: URL
    let batchName: String
    let workspace: String
    let projectSlug: String
}

class RoboflowService {
    static let shared = RoboflowService()

    private init() {}

    static let defaultUploadTag = "scout"

    // MARK: - Workspace & Project Discovery

    func listWorkspaces() async throws -> [Workspace] {
        let endpoint = "/"
        let request = URLRequest(url: URL(string: "https://api.roboflow.com/")!)
        let (data, http) = try await OAuthManager.shared.authorizedData(for: request)

        guard http.statusCode == 200 else {
            throw Self.apiError(status: http.statusCode, endpoint: endpoint, data: data)
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let workspaceSlug = json["workspace"] as? String {
                await MainActor.run {
                    if OAuthManager.shared.workspaceURL == nil {
                        OAuthManager.shared.workspaceURL = workspaceSlug
                    }
                }
                return [Workspace(url: workspaceSlug, name: workspaceSlug, members: 1)]
            }
            if let workspacesArray = json["workspaces"] as? [[String: Any]] {
                return workspacesArray.compactMap { dict -> Workspace? in
                    guard let url = dict["url"] as? String else { return nil }
                    let name = dict["name"] as? String ?? url
                    let members = dict["members"] as? Int ?? 1
                    return Workspace(url: url, name: name, members: members)
                }
            }
        }

        throw Self.apiError(status: http.statusCode, endpoint: endpoint, data: data,
                            fallback: "No workspace found in API response")
    }

    func listProjects(workspace: String) async throws -> [Project] {
        let endpoint = "/\(workspace)"
        let request = URLRequest(url: URL(string: "https://api.roboflow.com/\(workspace)")!)
        let (data, http) = try await OAuthManager.shared.authorizedData(for: request)

        guard http.statusCode == 200 else {
            throw Self.apiError(status: http.statusCode, endpoint: endpoint, data: data)
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projectsDict = json["workspace"] as? [String: Any],
           let projectsArray = projectsDict["projects"] as? [[String: Any]] {
            return projectsArray.compactMap { dict -> Project? in
                guard let id = dict["id"] as? String,
                      let name = dict["name"] as? String else {
                    return nil
                }
                return Project(id: id, name: name, workspace: workspace)
            }
        }

        return []
    }

    // MARK: - Zip upload (OAuth-safe path)

    /// Upload JPEGs via POST /{ws}/{project}/upload/zip → PUT signedUrl → poll → resolve ids.
    func uploadImagesViaZip(
        entries: [ZipUploadEntry],
        project: String,
        batchName: String,
        tags: [String] = [defaultUploadTag],
        onProgress: (@MainActor (String) -> Void)? = nil
    ) async throws -> ZipUploadResult {
        guard !entries.isEmpty else {
            let ws = try resolveWorkspace(from: project)
            let slug = projectSlug(from: project)
            return ZipUploadResult(
                imageIds: [:],
                batchId: nil,
                openURL: Self.annotateURL(workspace: ws, projectSlug: slug, batchId: nil),
                batchName: batchName,
                workspace: ws,
                projectSlug: slug
            )
        }

        let workspace = try resolveWorkspace(from: project)
        let projectSlug = projectSlug(from: project)

        await onProgress?("Preparing zip (\(entries.count) images)…")

        var zipEntries: [(name: String, data: Data)] = []
        zipEntries.reserveCapacity(entries.count)
        for entry in entries {
            zipEntries.append((name: "train/\(entry.imageName)", data: entry.jpegData))
        }
        let zipData = try StoreZipWriter.makeZip(entries: zipEntries)

        await onProgress?("Requesting upload slot…")
        let (taskId, signedUrl) = try await initiateZipUpload(
            workspace: workspace,
            projectSlug: projectSlug,
            batchName: batchName,
            tags: tags
        )

        await onProgress?("Uploading zip…")
        try await putSignedZip(signedUrl: signedUrl, zipData: zipData)

        await onProgress?("Processing upload…")
        let pollJSON = try await pollZipTask(workspace: workspace, taskId: taskId)

        await onProgress?("Looking up batch…")
        let batchId = await resolveBatchId(
            workspace: workspace,
            projectSlug: projectSlug,
            batchName: batchName,
            pollJSON: pollJSON
        )

        await onProgress?("Resolving image IDs…")
        var ids: [UUID: String] = [:]
        for entry in entries {
            let imageId = try await resolveImageId(
                workspace: workspace,
                projectSlug: projectSlug,
                filename: entry.imageName
            )
            ids[entry.frameId] = imageId
        }

        return ZipUploadResult(
            imageIds: ids,
            batchId: batchId,
            openURL: Self.annotateURL(workspace: workspace, projectSlug: projectSlug, batchId: batchId),
            batchName: batchName,
            workspace: workspace,
            projectSlug: projectSlug
        )
    }

    /// Web URLs from Roboflow product-navigation skill
    /// (github.com/roboflow/computer-vision-skills …/product-navigation/SKILL.md):
    /// Annotate `/{ws}/{proj}/annotate`, batch `/{ws}/{proj}/annotate/batch/{batchId}`.
    static func annotateURL(workspace: String, projectSlug: String, batchId: String?) -> URL {
        if let batchId, !batchId.isEmpty {
            return URL(string: "https://app.roboflow.com/\(workspace)/\(projectSlug)/annotate/batch/\(batchId)")!
        }
        return URL(string: "https://app.roboflow.com/\(workspace)/\(projectSlug)/annotate")!
    }

    private func initiateZipUpload(
        workspace: String,
        projectSlug: String,
        batchName: String,
        tags: [String]
    ) async throws -> (taskId: String, signedUrl: URL) {
        let endpoint = "/\(workspace)/\(projectSlug)/upload/zip"
        var request = URLRequest(url: URL(string: "https://api.roboflow.com\(endpoint)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "split": "train",
            "batchName": batchName,
            "tags": tags
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, http) = try await OAuthManager.shared.authorizedData(for: request)
        guard http.statusCode == 200 || http.statusCode == 201 else {
            throw Self.apiError(status: http.statusCode, endpoint: endpoint, data: data)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Self.apiError(status: http.statusCode, endpoint: endpoint, data: data,
                                fallback: "Invalid JSON from zip upload init")
        }

        let taskId = (json["taskId"] as? String)
            ?? (json["task_id"] as? String)
            ?? (json["id"] as? String)
        let urlString = (json["signedUrl"] as? String)
            ?? (json["signed_url"] as? String)
            ?? (json["url"] as? String)

        guard let taskId, let urlString, let signedUrl = URL(string: urlString) else {
            ScoutLog.decision("🔴 [ScoutUpload] zip init missing fields: \(String(data: data, encoding: .utf8) ?? "")")
            throw Self.apiError(status: http.statusCode, endpoint: endpoint, data: data,
                                fallback: "zip init missing taskId/signedUrl")
        }
        return (taskId, signedUrl)
    }

    private func putSignedZip(signedUrl: URL, zipData: Data) async throws {
        let endpoint = signedUrl.host.map { "PUT https://\($0)/…" } ?? "PUT signedUrl"
        var request = URLRequest(url: signedUrl)
        request.httpMethod = "PUT"
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        request.httpBody = zipData
        // Signed URL: no Authorization header

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RoboflowError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw Self.apiError(status: http.statusCode, endpoint: endpoint, data: data)
        }
    }

    private func pollZipTask(workspace: String, taskId: String) async throws -> [String: Any] {
        let endpoint = "/\(workspace)/upload/zip/\(taskId)"
        let url = URL(string: "https://api.roboflow.com\(endpoint)")!
        let deadline = Date().addingTimeInterval(180)

        while Date() < deadline {
            let request = URLRequest(url: url)
            let (data, http) = try await OAuthManager.shared.authorizedData(for: request)

            if http.statusCode != 200 {
                throw Self.apiError(status: http.statusCode, endpoint: endpoint, data: data)
            }

            let raw = String(data: data, encoding: .utf8) ?? ""
            ScoutLog.decision("🔵 [ScoutUpload] zip poll raw=\(raw.prefix(800))")

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Self.apiError(status: http.statusCode, endpoint: endpoint, data: data,
                                    fallback: "Invalid poll JSON")
            }

            let status = ((json["status"] as? String)
                ?? (json["state"] as? String)
                ?? "").lowercased()

            ScoutLog.decision("🔵 [ScoutUpload] zip task \(taskId) status=\(status)")

            if status == "completed" || status == "complete" || status == "success" || status == "succeeded" {
                if let result = json["result"] as? [String: Any] {
                    let uploaded = result["uploaded"] ?? result["success"]
                    let failed = result["failed"] ?? result["failure"]
                    ScoutLog.decision("🔵 [ScoutUpload] zip result uploaded=\(String(describing: uploaded)) failed=\(String(describing: failed)) errors=\(String(describing: result["errors"]))")
                }
                return json
            }
            if status == "failed" || status == "error" || status == "cancelled" {
                throw Self.apiError(status: http.statusCode, endpoint: endpoint, data: data,
                                    fallback: "Zip upload task \(status)")
            }

            try await Task.sleep(nanoseconds: 3_000_000_000)
        }

        throw RoboflowError.uploadFailed(message: "Zip upload task timed out after ~3 min (\(endpoint))")
    }

    /// Prefer batch id from zip status JSON; else GET /{ws}/{project}/batches and match name.
    private func resolveBatchId(
        workspace: String,
        projectSlug: String,
        batchName: String,
        pollJSON: [String: Any]
    ) async -> String? {
        if let fromPoll = extractBatchId(from: pollJSON) {
            ScoutLog.decision("🔵 [ScoutUpload] batch id from zip status: \(fromPoll)")
            return fromPoll
        }

        let endpoint = "/\(workspace)/\(projectSlug)/batches"
        let request = URLRequest(url: URL(string: "https://api.roboflow.com\(endpoint)")!)
        do {
            let (data, http) = try await OAuthManager.shared.authorizedData(for: request)
            let raw = String(data: data, encoding: .utf8) ?? ""
            ScoutLog.decision("🔵 [ScoutUpload] batches list status=\(http.statusCode) body=\(raw.prefix(800))")
            guard http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let batches = (json["batches"] as? [[String: Any]])
                ?? (json["data"] as? [[String: Any]])
                ?? []
            func batchDisplayName(_ b: [String: Any]) -> String? {
                (b["name"] as? String) ?? (b["batchName"] as? String) ?? (b["batch"] as? String)
            }
            if let match = batches.first(where: { batchDisplayName($0) == batchName }) {
                if let id = match["id"] as? String, !id.isEmpty {
                    ScoutLog.decision("🔵 [ScoutUpload] batch id from list match name=\(batchName): \(id)")
                    return id
                }
            }
            ScoutLog.decision("🟡 [ScoutUpload] no batch named \(batchName) in \(batches.count) batches")
        } catch {
            ScoutLog.decision("🟡 [ScoutUpload] batches list failed: \(error.localizedDescription)")
        }
        return nil
    }

    private func extractBatchId(from json: [String: Any]) -> String? {
        let keys = ["batchId", "batch_id", "batch", "sourceBatch", "source_batch"]
        for key in keys {
            if let s = json[key] as? String, !s.isEmpty { return s }
        }
        if let result = json["result"] as? [String: Any] {
            for key in keys {
                if let s = result[key] as? String, !s.isEmpty { return s }
            }
            if let batch = result["batch"] as? [String: Any], let id = batch["id"] as? String {
                return id
            }
        }
        // url field may contain …/annotate/batch/{id}
        for key in ["url", "signedUrl", "webUrl", "href"] {
            if let url = json[key] as? String,
               let range = url.range(of: "/annotate/batch/") {
                let rest = String(url[range.upperBound...])
                let id = rest.split(separator: "/").first.map(String.init)
                if let id, !id.isEmpty { return id }
            }
            if let result = json["result"] as? [String: Any],
               let url = result[key] as? String,
               let range = url.range(of: "/annotate/batch/") {
                let rest = String(url[range.upperBound...])
                let id = rest.split(separator: "/").first.map(String.init)
                if let id, !id.isEmpty { return id }
            }
        }
        return nil
    }

    private func resolveImageId(
        workspace: String,
        projectSlug: String,
        filename: String
    ) async throws -> String {
        let endpoint = "/\(workspace)/search/v1"
        let queries = [
            "project:\(projectSlug) filename:\(filename)",
            "project:\(projectSlug) filename:\"\(filename)\"",
            "filename:\(filename)",
            "filename:\"\(filename)\""
        ]

        var lastData = Data()
        var lastStatus = 0

        for attempt in 0..<6 {
            if attempt > 0 {
                let delay = UInt64(min(8, 1 << (attempt - 1))) * 500_000_000
                try await Task.sleep(nanoseconds: delay)
            }

            for query in queries {
                var request = URLRequest(url: URL(string: "https://api.roboflow.com\(endpoint)")!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let body: [String: Any] = [
                    "query": query,
                    "pageSize": 1,
                    "fields": ["id"]
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, http) = try await OAuthManager.shared.authorizedData(for: request)
                lastData = data
                lastStatus = http.statusCode

                let raw = String(data: data, encoding: .utf8) ?? ""
                ScoutLog.decision("🔵 [ScoutUpload] search q=\(query) status=\(http.statusCode) body=\(raw.prefix(400))")

                if http.statusCode != 200 {
                    continue
                }

                if let id = extractImageId(from: data) {
                    return id
                }
            }
        }

        throw Self.apiError(status: lastStatus, endpoint: endpoint, data: lastData,
                            fallback: "Could not resolve image id for \(filename)")
    }

    private func extractImageId(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

        if let dict = json as? [String: Any] {
            if let id = dict["id"] as? String { return id }
            for key in ["results", "images", "data", "items", "hits"] {
                if let arr = dict[key] as? [[String: Any]], let first = arr.first {
                    if let id = first["id"] as? String { return id }
                    if let id = first["_id"] as? String { return id }
                }
            }
        }
        if let arr = json as? [[String: Any]], let first = arr.first {
            if let id = first["id"] as? String { return id }
        }
        return nil
    }

    // MARK: - Annotate (null)

    /// Annotate as null using COCO JSON (SDK fake-annotation workaround).
    /// Uses workspace-path route that accepts OAuth Bearer tokens.
    func annotateAsNull(
        imageId: String,
        imageName: String,
        imageWidth: Int,
        imageHeight: Int,
        project: String
    ) async throws {
        let workspace = try resolveWorkspace(from: project)
        let projectSlug = projectSlug(from: project)

        let cocoJson: [String: Any] = [
            "info": [
                "description": "Scout null frame"
            ],
            "licenses": [],
            "categories": [
                [
                    "id": 0,
                    "name": "null",
                    "supercategory": "none"
                ]
            ],
            "images": [
                [
                    "id": 0,
                    "file_name": imageName,
                    "width": imageWidth,
                    "height": imageHeight
                ]
            ],
            "annotations": [
                [
                    "id": 999999999,
                    "image_id": 999999999,
                    "category_id": 0,
                    "area": 1,
                    "bbox": [0, 0, 1, 1],
                    "segmentation": [],
                    "iscrowd": 0
                ]
            ]
        ]

        guard let cocoJsonData = try? JSONSerialization.data(withJSONObject: cocoJson),
              let cocoJsonString = String(data: cocoJsonData, encoding: .utf8) else {
            throw RoboflowError.annotationFailed(message: "Failed to create COCO JSON")
        }

        var components = URLComponents(string: "https://api.roboflow.com/\(workspace)/\(projectSlug)/annotate/\(imageId)")!
        components.queryItems = [
            URLQueryItem(name: "name", value: "annotation.coco.json"),
            URLQueryItem(name: "overwrite", value: "true")
        ]

        guard let annotateURL = components.url else {
            throw RoboflowError.invalidURL
        }

        let endpoint = "/\(workspace)/\(projectSlug)/annotate/\(imageId)"
        var request = URLRequest(url: annotateURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "annotationFile": cocoJsonString
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, http) = try await OAuthManager.shared.authorizedData(for: request)
        let responseBody = String(data: data, encoding: .utf8) ?? ""

        if http.statusCode == 409 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String,
               message.contains("already annotated") {
                return
            }
            ScoutLog.decision("🔴 [ScoutNullify] 409 response: \(responseBody)")
        }

        guard http.statusCode == 200 else {
            ScoutLog.decision("🔴 [ScoutNullify] annotate failed status=\(http.statusCode) body=\(responseBody)")
            throw Self.apiError(status: http.statusCode, endpoint: endpoint, data: data)
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let success = json["success"] as? Bool, !success {
                throw Self.apiError(status: http.statusCode, endpoint: endpoint, data: data,
                                    fallback: "annotate success=false")
            }
        }
    }

    // MARK: - Helpers

    func resolveWorkspace(from project: String) throws -> String {
        if let slash = project.firstIndex(of: "/") {
            let ws = String(project[..<slash])
            if !ws.isEmpty { return ws }
        }
        if let ws = OAuthManager.shared.workspaceURL, !ws.isEmpty {
            return ws
        }
        throw RoboflowError.apiError(
            statusCode: 0,
            endpoint: "(workspace)",
            body: "Missing workspace for project \"\(project)\". Log in again or use workspace/project ids."
        )
    }

    func projectSlug(from project: String) -> String {
        project.split(separator: "/").last.map(String.init) ?? project
    }

    static func apiError(status: Int, endpoint: String, data: Data, fallback: String? = nil) -> RoboflowError {
        let raw = String(data: data, encoding: .utf8) ?? ""
        let body = raw.isEmpty ? (fallback ?? "(empty body)") : String(raw.prefix(500))
        return .apiError(statusCode: status, endpoint: endpoint, body: body)
    }
}

// MARK: - STORE zip (uncompressed) + CRC32

enum StoreZipWriter {
    static func makeZip(entries: [(name: String, data: Data)]) throws -> Data {
        var localParts: [Data] = []
        var centralParts: [Data] = []
        var offset: UInt32 = 0

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)

            var local = Data()
            local.append(contentsOf: u32(0x04034b50)) // local file header sig
            local.append(contentsOf: u16(20)) // version needed
            local.append(contentsOf: u16(0)) // flags
            local.append(contentsOf: u16(0)) // method STORE
            local.append(contentsOf: u16(0)) // time
            local.append(contentsOf: u16(0)) // date
            local.append(contentsOf: u32(crc))
            local.append(contentsOf: u32(size))
            local.append(contentsOf: u32(size))
            local.append(contentsOf: u16(UInt16(nameData.count)))
            local.append(contentsOf: u16(0)) // extra len
            local.append(nameData)
            local.append(entry.data)

            var central = Data()
            central.append(contentsOf: u32(0x02014b50)) // central dir sig
            central.append(contentsOf: u16(20)) // version made by
            central.append(contentsOf: u16(20)) // version needed
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0)) // STORE
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u32(crc))
            central.append(contentsOf: u32(size))
            central.append(contentsOf: u32(size))
            central.append(contentsOf: u16(UInt16(nameData.count)))
            central.append(contentsOf: u16(0))
            central.append(contentsOf: u16(0)) // comment
            central.append(contentsOf: u16(0)) // disk start
            central.append(contentsOf: u16(0)) // int attrs
            central.append(contentsOf: u32(0)) // ext attrs
            central.append(contentsOf: u32(offset))
            central.append(nameData)

            localParts.append(local)
            centralParts.append(central)
            offset += UInt32(local.count)
        }

        var out = Data()
        for part in localParts { out.append(part) }
        let centralOffset = UInt32(out.count)
        var centralSize: UInt32 = 0
        for part in centralParts {
            out.append(part)
            centralSize += UInt32(part.count)
        }

        // End of central directory
        out.append(contentsOf: u32(0x06054b50))
        out.append(contentsOf: u16(0)) // disk
        out.append(contentsOf: u16(0)) // disk with cd
        out.append(contentsOf: u16(UInt16(entries.count)))
        out.append(contentsOf: u16(UInt16(entries.count)))
        out.append(contentsOf: u32(centralSize))
        out.append(contentsOf: u32(centralOffset))
        out.append(contentsOf: u16(0)) // comment len
        return out
    }

    private static func u16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]
    }

    private static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                if c & 1 != 0 {
                    c = 0xedb88320 ^ (c >> 1)
                } else {
                    c = c >> 1
                }
            }
            return c
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xff)
            crc = crcTable[idx] ^ (crc >> 8)
        }
        return crc ^ 0xffffffff
    }
}

enum RoboflowError: LocalizedError {
    case authenticationRequired
    case imageConversionFailed
    case invalidURL
    case invalidResponse
    case apiError(statusCode: Int, endpoint: String, body: String)
    case uploadFailed(message: String)
    case annotationFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return "Please log in with Roboflow in Settings"
        case .imageConversionFailed:
            return "Failed to process image"
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .apiError(let statusCode, let endpoint, let body):
            return "HTTP \(statusCode) \(endpoint): \(body)"
        case .uploadFailed(let message):
            return "Upload failed: \(message)"
        case .annotationFailed(let message):
            return "Annotation failed: \(message)"
        }
    }
}
