import Foundation

/// Configure your deployed backend (see `api/README.md`). Set **AIApiBaseURL** in `HueGame/Info.plist` (merged with the generated Info.plist).
/// Override for testing: UserDefaults key `ai_api_base_override`.
enum AIModeClientConfig {
    /// HTTPS origin for your **deployment** (e.g. `https://color-que-iq.vercel.app`), not the `vercel.com/...` dashboard link.
    static var baseURL: URL? {
        if let o = UserDefaults.standard.string(forKey: "ai_api_base_override") {
            let t = normalizeBaseURLString(o)
            if let u = URL(string: t), isValidDeploymentBaseURL(u) { return u }
        }
        if let s = bundleAIApiBaseURLRawString() {
            let t = normalizeBaseURLString(s)
            guard !t.isEmpty, !t.contains("REPLACE_WITH_YOUR_VERCEL") else { return nil }
            guard let u = URL(string: t), isValidDeploymentBaseURL(u) else { return nil }
            return u
        }
        return nil
    }

    /// Merged Info.plist (generated + HueGame/Info.plist) — both lookup styles for reliability.
    private static func bundleAIApiBaseURLRawString() -> String? {
        if let s = Bundle.main.object(forInfoDictionaryKey: "AIApiBaseURL") as? String { return s }
        return Bundle.main.infoDictionary?["AIApiBaseURL"] as? String
    }

    /// Explains why `baseURL` is nil (wrong dashboard URL, placeholder, missing key, etc.).
    static func baseURLSetupMessage() -> String {
        if let s = bundleAIApiBaseURLRawString() {
            let t = normalizeBaseURLString(s)
            if t.isEmpty {
                return "AIApiBaseURL is empty. Set it to your deployment URL, e.g. https://color-que-iq.vercel.app"
            }
            if t.contains("REPLACE_WITH_YOUR_VERCEL") {
                return "Replace the AIApiBaseURL placeholder with your real .vercel.app URL."
            }
            guard let u = URL(string: t) else {
                return "AIApiBaseURL is not a valid URL."
            }
            let h = u.host?.lowercased() ?? ""
            if h == "vercel.com" || h == "www.vercel.com" {
                return "That link is the Vercel website, not your live API. In Vercel open this project → Deployments → pick the latest production deployment → copy the URL that ends in .vercel.app (no path after it). Paste that into AIApiBaseURL, then Product → Clean Build Folder and run again."
            }
        }
        return "Set AIApiBaseURL in HueGame/Info.plist to https://YOUR-PROJECT.vercel.app (from Vercel → Deployments). Clean build (Shift+Cmd+K), then run again."
    }

    private static func normalizeBaseURLString(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    private static func isValidDeploymentBaseURL(_ url: URL) -> Bool {
        guard let h = url.host?.lowercased() else { return false }
        if h == "vercel.com" || h == "www.vercel.com" { return false }
        return true
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
            return AIModeClientConfig.baseURLSetupMessage()
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
