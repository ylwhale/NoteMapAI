import Foundation

nonisolated struct OpenAIModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let summary: String
}

nonisolated enum OpenAIModelCatalog {
    static let customSelectionID = "__custom_openai_model__"

    static let curated: [OpenAIModelOption] = [
        OpenAIModelOption(
            id: "gpt-5.6-luna",
            name: "GPT-5.6 Luna",
            summary: "Efficient for everyday grounded conclusions."
        ),
        OpenAIModelOption(
            id: "gpt-5.6-terra",
            name: "GPT-5.6 Terra",
            summary: "Balanced capability and efficiency."
        ),
        OpenAIModelOption(
            id: "gpt-5.6-sol",
            name: "GPT-5.6 Sol",
            summary: "Highest capability for more demanding synthesis."
        )
    ]

    static func option(for modelID: String) -> OpenAIModelOption? {
        let cleaned = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return curated.first { $0.id == cleaned }
    }

    static func selectionID(for modelID: String) -> String {
        option(for: modelID)?.id ?? customSelectionID
    }
}

nonisolated struct OpenAIConnectionTestSuccess: Equatable, Sendable {
    let modelID: String
}

nonisolated enum OpenAIConnectionTestError: LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case missingModel
    case invalidAPIKey
    case billingOrQuota
    case modelUnavailable(String)
    case rateLimited(retryAfterSeconds: Int?)
    case networkUnavailable
    case timedOut
    case serverUnavailable
    case incompleteResponse
    case invalidResponse
    case requestRejected

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Save an OpenAI API key in the iOS Keychain before testing the connection."
        case .missingModel:
            return "Choose a model or enter a custom model ID before testing the connection."
        case .invalidAPIKey:
            return "OpenAI rejected this API key. Check that it is correct, active, and belongs to the intended OpenAI project, then save it again."
        case .billingOrQuota:
            return "The OpenAI project has no available credit or has reached a billing, spend, or usage limit. Review the project’s Billing and Limits settings before retrying."
        case .modelUnavailable(let model):
            return "The saved OpenAI project cannot use \(model). Choose another model or grant this project access to that model."
        case .rateLimited(let retryAfterSeconds):
            if let retryAfterSeconds {
                return "OpenAI is rate limiting requests. Wait about \(retryAfterSeconds) second\(retryAfterSeconds == 1 ? "" : "s"), then test again."
            }
            return "OpenAI is rate limiting requests. Wait briefly, then test again."
        case .networkUnavailable:
            return "MindMap AI could not reach OpenAI. Check the device connection, VPN, proxy, or firewall, then try again."
        case .timedOut:
            return "OpenAI did not respond before the connection test timed out. Your key and model selection were not changed."
        case .serverUnavailable:
            return "OpenAI is temporarily unavailable. Wait briefly, check the OpenAI status page if needed, then test again."
        case .incompleteResponse:
            return "OpenAI ended the connection test before returning its confirmation. Retry the test; if it keeps happening, choose another model or check the OpenAI status page."
        case .invalidResponse:
            return "OpenAI returned a response MindMap AI could not verify. No note content was sent and your settings were not changed."
        case .requestRejected:
            return "OpenAI rejected the setup test. Check the selected model and OpenAI project permissions, then try again."
        }
    }
}

nonisolated protocol OpenAIConnectionTesting: Sendable {
    func testConnection(apiKey: String, model: String) async throws -> OpenAIConnectionTestSuccess
}

/// Validates a Keychain-loaded API key, billing availability, and selected model using a fixed,
/// non-personal diagnostic prompt. No question, note, excerpt, plan, history, or location content
/// enters this service. The request uses an ephemeral URL session and asks OpenAI not to store it.
actor OpenAISetupService: OpenAIConnectionTesting {
    private struct ResponseEnvelope: Decodable {
        struct IncompleteDetails: Decodable {
            var reason: String?
        }

        struct OutputItem: Decodable {
            struct ContentItem: Decodable {
                var type: String
                var text: String?
            }

            var content: [ContentItem] = []

            enum CodingKeys: String, CodingKey {
                case content
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                content = try container.decodeIfPresent([ContentItem].self, forKey: .content) ?? []
            }
        }

        var model: String?
        var status: String?
        var incompleteDetails: IncompleteDetails?
        var output: [OutputItem] = []

        enum CodingKeys: String, CodingKey {
            case model
            case status
            case incompleteDetails = "incomplete_details"
            case output
        }
    }

    private struct DiagnosticPayload: Decodable {
        var ready: Bool
    }

    private struct ProviderErrorMetadata {
        var code: String
        var type: String
        var parameter: String
        var message: String
    }

    private let endpoint: URL
    private let session: URLSession

    init(
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!,
        session: URLSession? = nil
    ) {
        self.endpoint = endpoint
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 12
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func testConnection(apiKey: String, model: String) async throws -> OpenAIConnectionTestSuccess {
        let cleanedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKey.isEmpty else { throw OpenAIConnectionTestError.missingAPIKey }
        guard !cleanedModel.isEmpty else { throw OpenAIConnectionTestError.missingModel }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("Bearer \(cleanedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(model: cleanedModel))

        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()

            guard let http = response as? HTTPURLResponse else {
                throw OpenAIConnectionTestError.invalidResponse
            }

            guard (200..<300).contains(http.statusCode) else {
                throw Self.mappedProviderError(
                    statusCode: http.statusCode,
                    data: data,
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                    model: cleanedModel
                )
            }

            let decoded: ResponseEnvelope
            do {
                decoded = try JSONDecoder().decode(ResponseEnvelope.self, from: data)
            } catch {
                throw OpenAIConnectionTestError.invalidResponse
            }

            if decoded.status == "incomplete" || decoded.incompleteDetails != nil {
                throw OpenAIConnectionTestError.incompleteResponse
            }

            guard let outputText = decoded.output
                .flatMap(\.content)
                .first(where: { $0.type == "output_text" })?
                .text,
                let payloadData = outputText.data(using: .utf8),
                let payload = try? JSONDecoder().decode(DiagnosticPayload.self, from: payloadData),
                payload.ready else {
                throw OpenAIConnectionTestError.invalidResponse
            }

            let returnedModel = decoded.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return OpenAIConnectionTestSuccess(
                modelID: returnedModel.isEmpty ? cleanedModel : returnedModel
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw CancellationError()
            case .timedOut:
                throw OpenAIConnectionTestError.timedOut
            case .notConnectedToInternet,
                    .networkConnectionLost,
                    .cannotFindHost,
                    .cannotConnectToHost,
                    .dnsLookupFailed,
                    .internationalRoamingOff,
                    .dataNotAllowed,
                    .secureConnectionFailed:
                throw OpenAIConnectionTestError.networkUnavailable
            default:
                throw OpenAIConnectionTestError.networkUnavailable
            }
        } catch let error as OpenAIConnectionTestError {
            throw error
        } catch {
            throw OpenAIConnectionTestError.invalidResponse
        }
    }

    private func requestBody(model: String) -> [String: Any] {
        [
            "model": model,
            "store": false,
            "instructions": "This is a configuration test. Return the required JSON and nothing else.",
            "input": "MindMap AI connection test. No user content is included.",
            "max_output_tokens": 256,
            "reasoning": ["effort": "none"],
            "text": [
                "verbosity": "low",
                "format": [
                    "type": "json_schema",
                    "name": "mindmap_connection_test",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "ready": ["type": "boolean"]
                        ],
                        "required": ["ready"]
                    ]
                ]
            ]
        ]
    }

    private nonisolated static func mappedProviderError(
        statusCode: Int,
        data: Data,
        retryAfter: String?,
        model: String
    ) -> OpenAIConnectionTestError {
        let metadata = providerErrorMetadata(from: data)
        let code = metadata.code.lowercased()
        let type = metadata.type.lowercased()
        let parameter = metadata.parameter.lowercased()
        let message = metadata.message.lowercased()

        if statusCode == 401 {
            return .invalidAPIKey
        }

        let quotaCodes: Set<String> = [
            "credit_balance_exhausted",
            "organization_spend_limit_exceeded",
            "project_spend_limit_exceeded",
            "organization_usage_limit_exceeded"
        ]
        if statusCode == 402
            || quotaCodes.contains(code)
            || type == "insufficient_quota"
            || message.contains("quota")
            || message.contains("billing")
            || message.contains("credit balance")
            || message.contains("spend limit")
            || message.contains("usage limit") {
            return .billingOrQuota
        }

        let modelIsUnavailable = statusCode == 403
            || statusCode == 404
            || parameter == "model"
            || code.contains("model_not_found")
            || code.contains("model_not_available")
            || message.contains("model") && (
                message.contains("not found")
                    || message.contains("not exist")
                    || message.contains("access")
                    || message.contains("permission")
            )
        if modelIsUnavailable {
            return .modelUnavailable(model)
        }

        if statusCode == 429 {
            let seconds = retryAfter.flatMap { value -> Int? in
                guard let numeric = Double(value), numeric.isFinite, numeric >= 0 else { return nil }
                return Int(numeric.rounded(.up))
            }
            return .rateLimited(retryAfterSeconds: seconds)
        }

        if statusCode == 408 || statusCode == 504 {
            return .timedOut
        }

        if (500..<600).contains(statusCode) {
            return .serverUnavailable
        }

        return .requestRejected
    }

    private nonisolated static func providerErrorMetadata(from data: Data) -> ProviderErrorMetadata {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else {
            return ProviderErrorMetadata(code: "", type: "", parameter: "", message: "")
        }

        func stringValue(_ value: Any?) -> String {
            if let value = value as? String { return value }
            if let value { return String(describing: value) }
            return ""
        }

        return ProviderErrorMetadata(
            code: stringValue(error["code"]),
            type: stringValue(error["type"]),
            parameter: stringValue(error["param"]),
            message: stringValue(error["message"])
        )
    }
}
