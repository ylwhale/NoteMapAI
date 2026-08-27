import Foundation
import Testing
@testable import MindMapAI

@MainActor
struct OpenAISetupServiceTests {
    @Test("Curated models preserve the current default and Custom compatibility")
    func curatedModelCatalog() {
        #expect(OpenAIModelCatalog.curated.map(\.id) == [
            "gpt-5.6-luna",
            "gpt-5.6-terra",
            "gpt-5.6-sol"
        ])
        #expect(OpenAIModelCatalog.selectionID(for: "gpt-5.6-luna") == "gpt-5.6-luna")
        #expect(
            OpenAIModelCatalog.selectionID(for: "project-specific-model")
                == OpenAIModelCatalog.customSelectionID
        )
    }

    @Test("Connection test performs a fixed note-free Responses request")
    func successfulDiagnosticIsNoteFree() async throws {
        let endpoint = setupEndpoint("success")
        let recorder = OpenAISetupCapturedRequest()
        let apiKey = "sk-test-key-never-in-url-or-body"

        OpenAISetupURLProtocol.register(endpoint) { request in
            recorder.record(request)
            let response = HTTPURLResponse(
                url: endpoint,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = Data(#"{"model":"gpt-5.6-luna","status":"completed","incomplete_details":null,"output":[{"type":"message","content":[{"type":"output_text","text":"{\"ready\":true}"}]}]}"#.utf8)
            return (response, body)
        }
        defer { OpenAISetupURLProtocol.unregister(endpoint) }

        let service = OpenAISetupService(endpoint: endpoint, session: setupMockSession())
        let result = try await service.testConnection(
            apiKey: apiKey,
            model: "gpt-5.6-luna"
        )

        #expect(result == OpenAIConnectionTestSuccess(modelID: "gpt-5.6-luna"))
        let request = try #require(recorder.request)
        #expect(request.httpMethod == "POST")
        #expect(request.url == endpoint)
        #expect(request.url?.query == nil)
        let body = try #require(recorder.body)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(apiKey)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.url?.absoluteString.contains(apiKey) == false)

        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "gpt-5.6-luna")
        #expect(json["store"] as? Bool == false)
        #expect(json["input"] as? String == "MindMap AI connection test. No user content is included.")
        #expect(json["max_output_tokens"] as? Int == 256)
        let reasoning = try #require(json["reasoning"] as? [String: String])
        #expect(reasoning["effort"] == "none")
        let bodyText = String(decoding: body, as: UTF8.self)
        #expect(!bodyText.contains(apiKey))
        #expect(!bodyText.localizedCaseInsensitiveContains("note excerpt"))
    }

    @Test("Missing, invalid, and model-access setup failures are explicit")
    func credentialAndModelErrors() async throws {
        let service = OpenAISetupService(
            endpoint: setupEndpoint("local-validation"),
            session: setupMockSession()
        )

        await expectSetupError(.missingAPIKey) {
            try await service.testConnection(apiKey: "  ", model: "gpt-5.6-luna")
        }
        await expectSetupError(.missingModel) {
            try await service.testConnection(apiKey: "sk-test", model: "  ")
        }

        try await expectHTTPError(
            suffix: "invalid-key",
            model: "gpt-5.6-luna",
            statusCode: 401,
            body: #"{"error":{"message":"Incorrect API key","type":"invalid_request_error","code":"invalid_api_key"}}"#,
            expected: .invalidAPIKey
        )
        try await expectHTTPError(
            suffix: "model-access",
            model: "gpt-5.6-sol",
            statusCode: 404,
            body: #"{"error":{"message":"The model does not exist or you do not have access","type":"invalid_request_error","code":"model_not_found","param":"model"}}"#,
            expected: .modelUnavailable("gpt-5.6-sol")
        )
    }

    @Test("Quota, rate-limit, and server failures remain distinct")
    func providerCapacityErrors() async throws {
        try await expectHTTPError(
            suffix: "quota",
            model: "gpt-5.6-luna",
            statusCode: 429,
            body: #"{"error":{"message":"Credit balance exhausted","type":"insufficient_quota","code":"credit_balance_exhausted"}}"#,
            expected: .billingOrQuota
        )
        try await expectHTTPError(
            suffix: "rate-limit",
            model: "gpt-5.6-luna",
            statusCode: 429,
            headers: ["Retry-After": "2.2"],
            body: #"{"error":{"message":"Rate limit reached","type":"rate_limit_error","code":"rate_limit_exceeded"}}"#,
            expected: .rateLimited(retryAfterSeconds: 3)
        )
        try await expectHTTPError(
            suffix: "server",
            model: "gpt-5.6-luna",
            statusCode: 503,
            body: #"{"error":{"message":"Temporarily unavailable","type":"server_error","code":"server_error"}}"#,
            expected: .serverUnavailable
        )
    }

    @Test("Incomplete diagnostics have actionable retry guidance")
    func incompleteDiagnostic() async throws {
        let endpoint = setupEndpoint("incomplete")
        OpenAISetupURLProtocol.register(endpoint) { _ in
            let response = HTTPURLResponse(
                url: endpoint,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let body = Data(#"{"model":"gpt-5.6-luna","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"reasoning"}]}"#.utf8)
            return (response, body)
        }
        defer { OpenAISetupURLProtocol.unregister(endpoint) }

        let service = OpenAISetupService(endpoint: endpoint, session: setupMockSession())
        await expectSetupError(.incompleteResponse) {
            try await service.testConnection(apiKey: "sk-test", model: "gpt-5.6-luna")
        }
    }

    @Test("Network loss and timeout map to different recovery guidance")
    func transportErrors() async {
        await expectTransportError(
            suffix: "offline",
            thrown: URLError(.notConnectedToInternet),
            expected: .networkUnavailable
        )
        await expectTransportError(
            suffix: "timeout",
            thrown: URLError(.timedOut),
            expected: .timedOut
        )
    }

    @Test("Transport cancellation remains task cancellation")
    func transportCancellation() async {
        let endpoint = setupEndpoint("cancelled")
        OpenAISetupURLProtocol.register(endpoint) { _ in throw URLError(.cancelled) }
        defer { OpenAISetupURLProtocol.unregister(endpoint) }

        let service = OpenAISetupService(endpoint: endpoint, session: setupMockSession())
        do {
            _ = try await service.testConnection(apiKey: "sk-test", model: "gpt-5.6-luna")
            Issue.record("Expected the setup test to preserve cancellation.")
        } catch is CancellationError {
            // Expected: cancellation must not be presented as a network failure.
        } catch {
            Issue.record("Expected CancellationError, received \(error).")
        }
    }

    private func expectHTTPError(
        suffix: String,
        model: String,
        statusCode: Int,
        headers: [String: String] = [:],
        body: String,
        expected: OpenAIConnectionTestError
    ) async throws {
        let endpoint = setupEndpoint(suffix)
        OpenAISetupURLProtocol.register(endpoint) { _ in
            let response = HTTPURLResponse(
                url: endpoint,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (response, Data(body.utf8))
        }
        defer { OpenAISetupURLProtocol.unregister(endpoint) }

        let service = OpenAISetupService(endpoint: endpoint, session: setupMockSession())
        await expectSetupError(expected) {
            try await service.testConnection(apiKey: "sk-test", model: model)
        }
    }

    private func expectTransportError(
        suffix: String,
        thrown: URLError,
        expected: OpenAIConnectionTestError
    ) async {
        let endpoint = setupEndpoint(suffix)
        OpenAISetupURLProtocol.register(endpoint) { _ in throw thrown }
        defer { OpenAISetupURLProtocol.unregister(endpoint) }

        let service = OpenAISetupService(endpoint: endpoint, session: setupMockSession())
        await expectSetupError(expected) {
            try await service.testConnection(apiKey: "sk-test", model: "gpt-5.6-luna")
        }
    }

    private func expectSetupError(
        _ expected: OpenAIConnectionTestError,
        operation: () async throws -> OpenAIConnectionTestSuccess
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected setup test to fail with \(expected).")
        } catch let error as OpenAIConnectionTestError {
            #expect(error == expected)
            #expect(!error.localizedDescription.isEmpty)
        } catch {
            Issue.record("Unexpected setup-test error: \(error)")
        }
    }
}

private func setupEndpoint(_ suffix: String) -> URL {
    URL(string: "https://openai-setup.test/\(suffix)-\(UUID().uuidString)")!
}

private func setupMockSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenAISetupURLProtocol.self]
    return URLSession(configuration: configuration)
}

nonisolated private final class OpenAISetupCapturedRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?
    private var storedBody: Data?

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    var body: Data? {
        lock.lock()
        defer { lock.unlock() }
        return storedBody
    }

    func record(_ request: URLRequest) {
        let body = request.httpBody ?? Self.readBody(from: request.httpBodyStream)
        lock.lock()
        storedRequest = request
        storedBody = body
        lock.unlock()
    }

    private static func readBody(from stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

nonisolated private final class OpenAISetupURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(_ url: URL, handler: @escaping Handler) {
        lock.lock()
        handlers[url.absoluteString] = handler
        lock.unlock()
    }

    static func unregister(_ url: URL) {
        lock.lock()
        handlers.removeValue(forKey: url.absoluteString)
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let key = request.url?.absoluteString else { return false }
        lock.lock()
        defer { lock.unlock() }
        return handlers[key] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let key = request.url?.absoluteString else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let handler: Handler?
        Self.lock.lock()
        handler = Self.handlers[key]
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { }
}
