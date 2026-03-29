import Foundation

/// Configure your deployed backend (see `/api` in repo). Override in UserDefaults key `ai_api_base_override` for testing.
enum AIModeClientConfig {
    /// Base URL only, e.g. `https://xxx.vercel.app` — no trailing slash.
    static var baseURL: URL? {
        if let o = UserDefaults.standard.string(forKey: "ai_api_base_override"),
           let u = URL(string: o), !o.isEmpty {
            return u
        }
        if let s = Bundle.main.object(forInfoDictionaryKey: "AIApiBaseURL") as? String,
           let u = URL(string: s), !s.isEmpty {
            return u
        }
        return nil
    }
}

enum AIModeClientError: LocalizedError {
    case notConfigured
    case invalidURL
    case httpStatus(Int, String?)
    case decoding(Error)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "AI server URL is not configured. Set AIApiBaseURL in Info.plist or UserDefaults key ai_api_base_override."
        case .invalidURL:
            return "Invalid API URL."
        case .httpStatus(let code, let msg):
            return msg ?? "Server error (\(code))."
        case .decoding:
            return "Could not read puzzle from server."
        case .network(let e):
            return e.localizedDescription
        }
    }
}

@MainActor
final class AIModeClient {
    static let shared = AIModeClient()

    private init() {}

    func generatePuzzle(prompt: String, isPro: Bool) async throws -> AIPuzzleAPIResponse {
        guard let base = AIModeClientConfig.baseURL else {
            throw AIModeClientError.notConfigured
        }
        guard let url = URL(string: "/api/v1/ai-puzzle", relativeTo: base)?.absoluteURL else {
            throw AIModeClientError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let deviceId = AIQuotaDeviceId.value
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        let body: [String: Any] = [
            "prompt": prompt,
            "tier": isPro ? "pro" : "free"
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw AIModeClientError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIModeClientError.httpStatus(-1, nil)
        }

        if http.statusCode != 200 {
            let msg = String(data: data, encoding: .utf8)
            if let err = try? JSONDecoder().decode(AIPuzzleAPIErrorBody.self, from: data) {
                throw AIModeClientError.httpStatus(http.statusCode, err.message ?? err.error)
            }
            throw AIModeClientError.httpStatus(http.statusCode, msg)
        }

        do {
            return try JSONDecoder().decode(AIPuzzleAPIResponse.self, from: data)
        } catch {
            throw AIModeClientError.decoding(error)
        }
    }
}

/// Stable anonymous id for server-side daily quotas (not tied to Apple ID).
enum AIQuotaDeviceId {
    private static let key = "ai_quota_device_uuid"
    static var value: String {
        if let s = UserDefaults.standard.string(forKey: key), !s.isEmpty { return s }
        let u = UUID().uuidString
        UserDefaults.standard.set(u, forKey: key)
        return u
    }
}
