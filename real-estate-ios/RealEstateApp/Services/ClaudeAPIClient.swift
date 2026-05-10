import Foundation
import OSLog

private let logger = Logger(subsystem: "com.realestate", category: "ClaudeAPI")

final class ClaudeAPIClient: Sendable {
    static let shared = ClaudeAPIClient()

    private let session: URLSession
    private let baseURL = "https://api.anthropic.com/v1/messages"
    private let model = "claude-sonnet-4-20250514"
    private let maxTokens = 1024

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
    }

    var isAvailable: Bool {
        !Secrets.claudeAPIKey.isEmpty
    }

    // MARK: - Messages API

    func sendMessage(
        system: String,
        userContent: String
    ) async throws -> String {
        guard isAvailable else {
            throw ClaudeAPIError.notConfigured
        }

        guard let url = URL(string: baseURL) else {
            throw ClaudeAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Secrets.claudeAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = MessagesRequest(
            model: model,
            max_tokens: maxTokens,
            system: system,
            messages: [Message(role: "user", content: userContent)]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.error("Network error: \(error.localizedDescription, privacy: .public)")
            throw ClaudeAPIError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("API error \(httpResponse.statusCode, privacy: .public): \(body, privacy: .private)")
            if let err = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw ClaudeAPIError.apiError(httpResponse.statusCode, err.error.message)
            }
            throw ClaudeAPIError.apiError(httpResponse.statusCode, body)
        }

        let decoded: MessagesResponse
        do {
            decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
        } catch {
            logger.error("Response decode failed: \(error.localizedDescription, privacy: .public)")
            throw ClaudeAPIError.emptyResponse
        }

        guard let text = decoded.content.first(where: { $0.type == "text" })?.text else {
            throw ClaudeAPIError.emptyResponse
        }

        if let usage = decoded.usage {
            logger.info("Usage: in=\(usage.input_tokens) out=\(usage.output_tokens)")
        }

        return text
    }
}

// MARK: - Request/Response Types

extension ClaudeAPIClient {
    struct Message: Codable {
        let role: String
        let content: String
    }

    struct MessagesRequest: Codable {
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Message]
    }

    struct ContentBlock: Codable {
        let type: String
        let text: String?
    }

    struct MessagesResponse: Codable {
        let content: [ContentBlock]
        let stop_reason: String?
        let usage: Usage?
    }

    struct Usage: Codable {
        let input_tokens: Int
        let output_tokens: Int
    }

    struct APIError: Codable {
        let type: String
        let message: String
    }

    struct ErrorResponse: Codable {
        let error: APIError
    }
}

// MARK: - Error

enum ClaudeAPIError: Error, LocalizedError {
    case notConfigured
    case invalidURL
    case invalidResponse
    case networkError(String)
    case apiError(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Claude API キーが設定されていません"
        case .invalidURL: "Claude API URL が不正です"
        case .invalidResponse: "Claude API レスポンスが不正です"
        case .networkError(let msg): "ネットワークエラー: \(msg)"
        case .apiError(let code, _): "Claude API エラー (HTTP \(code))"
        case .emptyResponse: "Claude API: 空のレスポンス"
        }
    }
}
