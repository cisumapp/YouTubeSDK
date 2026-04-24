//
//  NetworkClient.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 26/12/25.
//

import Foundation

/// The simplified networking engine.
/// It takes the Context we built and sends it to the URLs we defined.
public actor NetworkClient {
    
    private let context: InnerTubeContext
    private let session: URLSession
    private let baseURL: String
    
    /// - Parameters:
    /// - baseURL: The host URL (e.g., "https://music.youtube.com/youtubei")
    /// - easier usage: `YouTubeSDKConstants.URLS.API.<api you want to use>`
    public init(context: InnerTubeContext, session: URLSession = .shared, baseURL: String = YouTubeSDKConstants.URLS.API.youtubeInnerTubeURL) {
        self.context = context
        self.session = session
        self.baseURL = baseURL
    }
    
    /// Sends a request to YouTube.
    /// - Parameters:
    ///   - endpoint: The API path (e.g., "/v1/player")
    ///   - body: The unique data for this request (e.g., ["videoId": "123"])
    /// - Returns: The decoded response
    /// Sends a request and decodes it immediately.
    public func send<T: Decodable>(_ endpoint: String, body: [String: String] = [:]) async throws -> T {
        let data = try await get(endpoint, body: body)
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }
    
    /// Sends a request and returns the Raw Data (no decoding).
    /// Useful for complex endpoints where we need to inspect the JSON before decoding.
    public func get(_ endpoint: String, body: [String: String] = [:]) async throws -> Data {
        let typedBody = body.reduce(into: [String: Any]()) { partialResult, item in
            partialResult[item.key] = item.value
        }
        return try await sendRawRequest(endpoint, body: typedBody)
    }

    /// Specifically for fetching HTML pages or static scripts (uses GET).
    public func fetchRawHTML(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        // Use the context headers (User-Agent is critical)
        for (key, value) in context.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
    
    // Overload for complex bodies (needed for Charts & Analytics)
    /// Sends a request with a complex nested body (required for Like, Subscribe, etc.)
    public func sendComplexRequest(
        _ endpoint: String,
        body: [String: Any],
        queryItems: [URLQueryItem] = [],
        additionalHeaders: [String: String] = [:]
    ) async throws -> Data {
        return try await sendRawRequest(
            endpoint,
            body: body,
            queryItems: queryItems,
            additionalHeaders: additionalHeaders
        )
    }

    /// Sends a request like `sendComplexRequest` but injects `visitorData` into the
    /// nested `context.client.visitorData` path while preserving the rest of the
    /// generated `context` payload. This is required for certain player requests.
    public func sendWithVisitorData(
        _ endpoint: String,
        body: [String: Any] = [:],
        visitorData: String? = nil,
        queryItems: [URLQueryItem] = [],
        additionalHeaders: [String: String] = [:]
    ) async throws -> Data {
        var payload = context.body

        // Inject visitorData into context.client while preserving other context fields
        if let visitor = visitorData {
            if var contextObj = payload["context"] as? [String: Any] {
                if var clientObj = contextObj["client"] as? [String: Any] {
                    clientObj["visitorData"] = visitor
                    contextObj["client"] = clientObj
                } else {
                    contextObj["client"] = ["visitorData": visitor]
                }
                payload["context"] = contextObj
            } else {
                payload["context"] = ["client": ["visitorData": visitor]]
            }
        }

        // Merge caller-provided top-level fields (e.g., videoId)
        for (key, value) in body {
            payload[key] = value
        }

        let url = try makeEndpointURL(endpoint, additionalQueryItems: queryItems)
        YouTubeDebugLogger.log("Sending request to \(url.path) (visitorDataInjected=\(visitorData != nil))")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        for (key, value) in context.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let host = URL(string: baseURL)?.host {
            let origin = "https://\(host)"
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue("\(origin)/", forHTTPHeaderField: "Referer")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            YouTubeDebugLogger.log("Request to \(url.path) failed: No HTTP response")
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode != 200 {
            YouTubeDebugLogger.log("Request to \(url.path) failed with status \(httpResponse.statusCode)")
            if let requestBody = request.httpBody,
               let requestBodyString = String(data: requestBody, encoding: .utf8) {
                print("❌ YouTube Request URL: \(url.absoluteString)")
                print("❌ YouTube Request Body: \(requestBodyString)")
            }
            if let errorString = String(data: data, encoding: .utf8) {
                print("❌ YouTube Error (\(httpResponse.statusCode)): \(errorString)")
            }
            throw URLError(.badServerResponse)
        }

        YouTubeDebugLogger.log("Request to \(url.path) succeeded (\(data.count) bytes)")
        return data
    }

    private func sendRawRequest(
        _ endpoint: String,
        body: [String: Any],
        queryItems: [URLQueryItem] = [],
        additionalHeaders: [String: String] = [:]
    ) async throws -> Data {
        let url = try makeEndpointURL(endpoint, additionalQueryItems: queryItems)
        YouTubeDebugLogger.log("Sending request to \(url.path)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        for (key, value) in context.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let host = URL(string: baseURL)?.host {
            let origin = "https://\(host)"
            request.setValue(origin, forHTTPHeaderField: "Origin")
            request.setValue("\(origin)/", forHTTPHeaderField: "Referer")
        }

        var payload = context.body
        for (key, value) in body {
            payload[key] = value
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            YouTubeDebugLogger.log("Request to \(url.path) failed: No HTTP response")
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode != 200 {
            YouTubeDebugLogger.log("Request to \(url.path) failed with status \(httpResponse.statusCode)")
            if let requestBody = request.httpBody,
               let requestBodyString = String(data: requestBody, encoding: .utf8) {
                print("❌ YouTube Request URL: \(url.absoluteString)")
                print("❌ YouTube Request Body: \(requestBodyString)")
            }
            if let errorString = String(data: data, encoding: .utf8) {
                print("❌ YouTube Error (\(httpResponse.statusCode)): \(errorString)")
            }
            throw URLError(.badServerResponse)
        }

        YouTubeDebugLogger.log("Request to \(url.path) succeeded (\(data.count) bytes)")
        return data
    }

    private func makeEndpointURL(_ endpoint: String, additionalQueryItems: [URLQueryItem] = []) throws -> URL {
        // If the endpoint is already a full URL, use it directly
        if let absoluteURL = URL(string: endpoint), absoluteURL.scheme != nil {
            var components = URLComponents(url: absoluteURL, resolvingAgainstBaseURL: true)
            var queryItems = components?.queryItems ?? []
            // Add the API key if it's not already there (though usually only needed for InnerTube endpoints)
            if !queryItems.contains(where: { $0.name == "key" }) {
                queryItems.append(URLQueryItem(name: "key", value: context.apiKey))
            }
            queryItems.append(contentsOf: additionalQueryItems)
            components?.queryItems = queryItems
            
            guard let finalURL = components?.url else { throw URLError(.badURL) }
            return finalURL
        }

        guard let rootURL = URL(string: baseURL) else {
            throw URLError(.badURL)
        }

        let trimmed = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath: String
        if trimmed.isEmpty {
            endpointPath = "v1"
        } else if trimmed == "v1" || trimmed.hasPrefix("v1/") {
            endpointPath = trimmed
        } else {
            endpointPath = "v1/\(trimmed)"
        }

        var components = URLComponents(url: rootURL.appendingPathComponent(endpointPath), resolvingAgainstBaseURL: true)
        var queryItems = [URLQueryItem(name: "key", value: context.apiKey)]
        queryItems.append(contentsOf: additionalQueryItems)
        components?.queryItems = queryItems

        guard let finalURL = components?.url else {
            throw URLError(.badURL)
        }

        return finalURL
    }
}
