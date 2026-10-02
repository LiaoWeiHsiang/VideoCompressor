import XCTest
@testable import VideoCompressor

/// The Immich upload, checked against a stub that records what was actually sent.
///
/// The real server needs credentials this project deliberately does not hold, so what is
/// verified here is the part that can be got wrong without noticing: the multipart body.
/// Field names come from Immich's own OpenAPI spec — widely-copied examples still send
/// `deviceAssetId` and `deviceId`, which the current schema does not define.
final class ImmichClientTests: XCTestCase {

    // MARK: - Stub transport

    /// Captures the request instead of sending it, so the body can be inspected.
    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var lastRequestBody: Data?
        nonisolated(unsafe) static var lastHeaders: [String: String] = [:]
        nonisolated(unsafe) static var lastURL: URL?
        nonisolated(unsafe) static var status = 201
        nonisolated(unsafe) static var responseBody = #"{"id":"abc-123","status":"created"}"#

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastURL = request.url
            Self.lastHeaders = request.allHTTPHeaderFields ?? [:]
            // URLSession moves an upload body to a stream; read the file it came from.
            if let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                let size = 1 << 16
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                defer { buffer.deallocate(); stream.close() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: size)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                Self.lastRequestBody = data
            } else {
                Self.lastRequestBody = request.httpBody
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(Self.responseBody.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeClient(server: String = "https://immich.example.com") -> ImmichClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ImmichClient(
            credentials: .init(serverURL: URL(string: server)!, apiKey: "test-key"),
            session: URLSession(configuration: configuration)
        )
    }

    private func makeFile(_ contents: String = "video-bytes") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        try Data(contents.utf8).write(to: url)
        return url
    }

    override func setUp() {
        super.setUp()
        StubProtocol.status = 201
        StubProtocol.responseBody = #"{"id":"abc-123","status":"created"}"#
        StubProtocol.lastRequestBody = nil
    }

    // MARK: - Body

    func testUploadSendsExactlyTheFieldsTheSchemaDeclares() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }

        _ = try await makeClient().upload(
            fileURL: file,
            createdAt: ISO8601DateFormatter().date(from: "2026-08-15T20:39:00Z")!,
            filename: "202608152039_compressed.mp4"
        )

        let body = String(data: try XCTUnwrap(StubProtocol.lastRequestBody), encoding: .utf8) ?? ""
        for field in ["assetData", "fileCreatedAt", "fileModifiedAt", "filename"] {
            XCTAssertTrue(body.contains("name=\"\(field)\""), "missing required field \(field)")
        }
        // Sending fields the schema does not define is how the widely-copied examples fail.
        for stale in ["deviceAssetId", "deviceId"] {
            XCTAssertFalse(body.contains("name=\"\(stale)\""),
                           "\(stale) is not in the current schema and should not be sent")
        }
        XCTAssertTrue(body.contains("2026-08-15T20:39:00Z"), "the shooting date was not sent")
        XCTAssertTrue(body.contains("video-bytes"), "the file contents were not included")
    }

    func testUploadSendsTheApiKeyAndChecksumHeaders() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }

        _ = try await makeClient().upload(fileURL: file, createdAt: Date())

        XCTAssertEqual(StubProtocol.lastHeaders["x-api-key"], "test-key")
        XCTAssertNotNil(StubProtocol.lastHeaders["x-immich-checksum"],
                        "without a checksum the server re-reads every duplicate")
    }

    /// A bare host and one already ending in /api both have to work — people paste either.
    func testServerURLAcceptsBothFormsWithoutDoublingTheApiPath() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }

        for server in ["https://immich.example.com", "https://immich.example.com/", "https://immich.example.com/api"] {
            _ = try await makeClient(server: server).upload(fileURL: file, createdAt: Date())
            let url = try XCTUnwrap(StubProtocol.lastURL).absoluteString
            XCTAssertEqual(url, "https://immich.example.com/api/assets", "wrong URL from \(server)")
        }
    }

    // MARK: - Outcomes

    /// 201 means stored, 200 means the server already had it. Conflating them makes a
    /// re-run look like it uploaded everything twice.
    func testCreatedAndDuplicateAreDistinguished() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }

        StubProtocol.status = 201
        let created = try await makeClient().upload(fileURL: file, createdAt: Date())
        XCTAssertEqual(created, .created(id: "abc-123"))

        StubProtocol.status = 200
        let duplicate = try await makeClient().upload(fileURL: file, createdAt: Date())
        XCTAssertEqual(duplicate, .duplicate(id: "abc-123"))
    }

    func testUnauthorizedIsReportedAsABadKeyRatherThanAGenericFailure() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }

        StubProtocol.status = 401
        StubProtocol.responseBody = #"{"message":"Invalid API key"}"#

        do {
            _ = try await makeClient().upload(fileURL: file, createdAt: Date())
            XCTFail("a 401 should not be treated as success")
        } catch let failure as ImmichClient.Failure {
            XCTAssertEqual(failure, .unauthorized)
        }
    }

    // MARK: - Credential storage

    /// The key must not be readable from the app's plist — that file rides along in
    /// backups.
    func testApiKeyIsNotStoredInUserDefaults() {
        ImmichCredentialStore.apiKey = "secret-value-12345"
        defer { ImmichCredentialStore.clear() }

        let defaults = UserDefaults.standard.dictionaryRepresentation()
        for (key, value) in defaults {
            if let text = value as? String {
                XCTAssertFalse(text.contains("secret-value-12345"),
                               "the API key leaked into UserDefaults under \(key)")
            }
        }
        XCTAssertEqual(ImmichCredentialStore.apiKey, "secret-value-12345",
                       "the key should still be readable from the Keychain")
    }

    func testCredentialsAreIncompleteUntilBothHalvesAreSet() {
        ImmichCredentialStore.clear()
        defer { ImmichCredentialStore.clear() }

        ImmichCredentialStore.serverURLString = "https://immich.example.com"
        XCTAssertNil(ImmichCredentialStore.credentials, "a server with no key is not usable")

        ImmichCredentialStore.apiKey = "k"
        XCTAssertNotNil(ImmichCredentialStore.credentials)
    }
}

/// ATS-related behaviour. Reported as "連不到 immich ... App Transport Security policy
/// requires the use of a secure connection": the app had no ATS configuration at all, so
/// iOS blocked the plain-HTTP address a self-hosted Immich normally runs on.
extension ImmichClientTests {

    /// The exception must stay the narrow one. `NSAllowsArbitraryLoads` would also permit
    /// cleartext to any public address typed by mistake, carrying the API key in the clear.
    func testLocalNetworkingIsAllowedButNotArbitraryLoads() throws {
        let ats = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any],
            "no ATS configuration — plain-HTTP servers on the LAN cannot be reached"
        )
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
        XCTAssertNil(ats["NSAllowsArbitraryLoads"],
                     "blanket cleartext would allow the API key over the public internet")
    }

    /// iOS's own wording never says what to change, so it must not be what the user sees.
    func testATSRefusalBecomesAnActionableMessage() {
        let atsError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorAppTransportSecurityRequiresSecureConnection
        )
        let failure = ImmichClient.describe(atsError)
        XCTAssertEqual(failure, .insecureConnectionBlocked)
        let message = try? XCTUnwrap(failure.errorDescription)
        XCTAssertTrue(message?.contains("https") == true,
                      "the message should say what to use instead")
    }

    /// Whether ATS actually lets a request to a tailnet host through.
    ///
    /// Asserted by making the request: ATS rejects before any packet leaves the device and
    /// reports -1022, so *any other* outcome — including a plain connection failure — proves
    /// the policy allowed it. Checking the Info.plist alone would only prove the key is
    /// spelled right, not that iOS honours it.
    private func atsVerdict(for urlString: String) async -> Int? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            _ = try await URLSession.shared.data(for: request)
            return 0                      // connected, so certainly not blocked
        } catch {
            return (error as NSError).code
        }
    }

    func testTailnetHostIsNotBlockedByATS() async {
        // A name that resolves nowhere: the request must fail, but it must fail for a
        // network reason rather than being refused by policy.
        let code = await atsVerdict(for: "http://no-such-machine.tail0000000.ts.net:2283/api/server/ping")
        XCTAssertNotEqual(code, NSURLErrorAppTransportSecurityRequiresSecureConnection,
                          "ATS is still blocking cleartext to a Tailscale hostname")
    }

    /// And the exception must not have become a blanket one. A public cleartext address is
    /// where the API key would be exposed, so it has to stay refused.
    func testPublicCleartextIsStillBlocked() async {
        let code = await atsVerdict(for: "http://neverssl.com/")
        XCTAssertEqual(code, NSURLErrorAppTransportSecurityRequiresSecureConnection,
                       "cleartext to a public host should still be refused by ATS")
    }

    /// An ordinary network failure must keep its own detail rather than being reported as
    /// an ATS problem.
    func testOtherNetworkErrorsAreNotMisreportedAsATS() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        guard case .serverUnreachable = ImmichClient.describe(offline) else {
            return XCTFail("an offline error should stay an unreachable-server error")
        }
    }
}
