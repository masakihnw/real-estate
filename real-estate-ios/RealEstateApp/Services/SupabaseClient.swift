//
//  SupabaseClient.swift
//  RealEstateApp
//
//  Supabase REST API (PostgREST) 用の軽量 HTTP クライアント。
//  外部 SDK 不要 — URLSession + JSON で直接通信する。
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.realestate", category: "Supabase")

final class SupabaseClient {
    static let shared = SupabaseClient()

    let baseURL = "https://dzhcumdmzskkvusynmyw.supabase.co"
    let anonKey = "sb_publishable_5PQ2vMg5w76yilwV9WlRUg_2jUyoH8l"

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - REST API

    /// PostgREST SELECT クエリ (GET)
    func select(
        from table: String,
        columns: String = "*",
        filters: [(String, String)] = [],
        order: String? = nil,
        range: ClosedRange<Int>? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var urlString = "\(baseURL)/rest/v1/\(table)?select=\(columns)"
        for (key, value) in filters {
            urlString += "&\(key)=\(value)"
        }
        if let order = order {
            urlString += "&order=\(order)"
        }

        guard let url = URL(string: urlString) else {
            throw SupabaseError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let range = range {
            request.setValue("\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
            request.setValue("items", forHTTPHeaderField: "Range-Unit")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 206 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("Supabase error \(httpResponse.statusCode): \(body, privacy: .public)")
            throw SupabaseError.httpError(httpResponse.statusCode, body)
        }

        return (data, httpResponse)
    }

    /// RPC 関数呼び出し (POST)
    func rpc(
        _ functionName: String,
        params: [String: Any] = [:]
    ) async throws -> Data {
        guard let url = URL(string: "\(baseURL)/rest/v1/rpc/\(functionName)") else {
            throw SupabaseError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: params)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("Supabase RPC error \(httpResponse.statusCode): \(body, privacy: .public)")
            throw SupabaseError.httpError(httpResponse.statusCode, body)
        }

        return data
    }

    /// Content-Range ヘッダーから総件数を抽出 ("0-99/350" → 350)
    static func parseTotalCount(from response: HTTPURLResponse) -> Int? {
        guard let contentRange = response.value(forHTTPHeaderField: "Content-Range") else {
            return nil
        }
        if let slashIndex = contentRange.lastIndex(of: "/") {
            let countStr = contentRange[contentRange.index(after: slashIndex)...]
            return Int(countStr)
        }
        return nil
    }
}

// MARK: - Error

enum SupabaseError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Supabase URL が不正です"
        case .invalidResponse: return "サーバーからのレスポンスが不正です"
        case .httpError(let code, _): return "Supabase エラー (HTTP \(code))"
        case .decodingError(let msg): return "デコードエラー: \(msg)"
        }
    }
}
