import Foundation
import CryptoKit

/// Uploads finished videos to a self-hosted Immich server.
///
/// Field names and requirements come from Immich's own OpenAPI spec
/// (`AssetMediaCreateDto`), not from blog posts: several widely-copied examples still send
/// `deviceAssetId` and `deviceId`, which the current schema does not define at all.
struct ImmichClient {

    struct Credentials: Equatable {
        var serverURL: URL
        var apiKey: String
    }

    enum UploadOutcome: Equatable {
        /// The server stored it.
        case created(id: String)
        /// The server already had this exact file. Not an error — re-running a batch
        /// should be safe, and Immich reports it with 200 rather than 201.
        case duplicate(id: String)
    }

    enum Failure: LocalizedError, Equatable {
        case badServerURL
        case unauthorized
        case serverUnreachable(String)
        case rejected(status: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .badServerURL:
                return "伺服器網址無效"
            case .unauthorized:
                return "API 金鑰無效或已失效"
            case .serverUnreachable(let detail):
                return "無法連線到伺服器：\(detail)"
            case .rejected(let status, let body):
                return "伺服器拒絕上傳（HTTP \(status)）：\(body)"
            }
        }
    }

    let credentials: Credentials
    var session: URLSession = .shared

    // MARK: - Connection checks

    /// Whether the address points at an Immich server *at all* — deliberately separate from
    /// the key check, because "wrong address" and "wrong key" need different fixes and a
    /// single combined "connection failed" leaves the user guessing which.
    func checkServerReachable() async throws {
        let url = try endpoint("server/ping")
        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw Failure.serverUnreachable("非預期的回應")
            }
            // Ping answers {"res":"pong"}; anything else is some other server on that address.
            guard let body = String(data: data, encoding: .utf8), body.contains("pong") else {
                throw Failure.serverUnreachable("這個網址不是 Immich 伺服器")
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.serverUnreachable(error.localizedDescription)
        }
    }

    /// Whether the key is accepted. Returns the account name, so the settings screen can
    /// show *which* account — a key for the wrong server or wrong user otherwise looks
    /// identical to a correct one.
    @discardableResult
    func checkCredentials() async throws -> String {
        let url = try endpoint("users/me")
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(credentials.apiKey, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.serverUnreachable("非預期的回應")
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw Failure.unauthorized }
        guard http.statusCode == 200 else {
            throw Failure.rejected(status: http.statusCode, body: Self.text(data))
        }

        let account = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (account?["email"] as? String) ?? (account?["name"] as? String) ?? "已連線"
    }

    // MARK: - Upload

    /// Uploads one file.
    ///
    /// `fileCreatedAt` is the shooting date rather than the encode time, so the video lands
    /// on the right day in Immich's timeline — the whole reason the date is written into
    /// the file in the first place.
    func upload(
        fileURL: URL,
        createdAt: Date,
        modifiedAt: Date? = nil,
        filename: String? = nil
    ) async throws -> UploadOutcome {
        let url = try endpoint("assets")
        let boundary = "Boundary-\(UUID().uuidString)"
        let name = filename ?? fileURL.lastPathComponent

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(credentials.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // Lets the server recognise a file it already has without reading the upload.
        if let checksum = Self.sha1Base64(of: fileURL) {
            request.setValue(checksum, forHTTPHeaderField: "x-immich-checksum")
        }

        let body = try Self.multipartBody(
            boundary: boundary,
            fileURL: fileURL,
            filename: name,
            createdAt: createdAt,
            modifiedAt: modifiedAt ?? createdAt
        )

        // uploadTask streams from disk rather than holding the whole video in memory.
        let (data, response) = try await session.upload(for: request, fromFile: body)
        try? FileManager.default.removeItem(at: body)

        guard let http = response as? HTTPURLResponse else {
            throw Failure.serverUnreachable("非預期的回應")
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw Failure.unauthorized }
        guard http.statusCode == 200 || http.statusCode == 201 else {
            throw Failure.rejected(status: http.statusCode, body: Self.text(data))
        }

        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let id = (parsed?["id"] as? String) ?? ""
        // 201 means stored, 200 means the server already had it. Reporting the difference
        // stops a re-run looking like it uploaded everything twice.
        return http.statusCode == 201 ? .created(id: id) : .duplicate(id: id)
    }

    // MARK: - Body

    /// Writes the multipart body to a file so a large video is never held in memory.
    static func multipartBody(
        boundary: String,
        fileURL: URL,
        filename: String,
        createdAt: Date,
        modifiedAt: Date
    ) throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("immich-\(UUID().uuidString).body")
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: bodyURL)
        defer { try? handle.close() }

        func writeField(_ name: String, _ value: String) throws {
            let part = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
            try handle.write(contentsOf: Data(part.utf8))
        }

        // Exactly the fields AssetMediaCreateDto declares. `deviceAssetId` and `deviceId`
        // appear in many older examples but are not part of the current schema.
        try writeField("fileCreatedAt", formatter.string(from: createdAt))
        try writeField("fileModifiedAt", formatter.string(from: modifiedAt))
        try writeField("filename", filename)

        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(filename)\"\r\nContent-Type: video/mp4\r\n\r\n"
        try handle.write(contentsOf: Data(header.utf8))

        let source = try FileHandle(forReadingFrom: fileURL)
        defer { try? source.close() }
        while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
        }

        try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return bodyURL
    }

    // MARK: - Helpers

    private func endpoint(_ path: String) throws -> URL {
        // Accepts a bare host or one already ending in /api, since both are what people
        // paste out of their browser.
        var base = credentials.serverURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/api") { base += "/api" }
        guard let url = URL(string: base + "/" + path) else { throw Failure.badServerURL }
        return url
    }

    /// Immich matches duplicates on the SHA-1 of the file, base64 encoded.
    static func sha1Base64(of fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        // `try?` already flattens the optional, so `chunk` is a plain Data here.
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize()).base64EncodedString()
    }

    private static func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8)?.prefix(300).description ?? "(無內容)"
    }
}
