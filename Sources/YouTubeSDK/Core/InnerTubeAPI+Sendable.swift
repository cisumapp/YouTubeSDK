import Foundation

public struct JSONSendable: @unchecked Sendable {
    public let value: [String: Any]
    public init(_ value: [String: Any]) { self.value = value }
}

extension InnerTubeAPI {
    func postSendable(endpoint: String, body: [String: Any], useAuth: Bool = false) async throws -> JSONSendable {
        var finalBody = makeBody(client: webClientContext)
        for (key, value) in body {
            finalBody[key] = value
        }
        let result = try await post(endpoint: endpoint, body: finalBody, useAuth: useAuth)
        return JSONSendable(result)
    }
}
