import Foundation

/// Fetches per-user access tokens from the partner backend at runtime.
///
/// The backend exposes `POST /api/user-token` with body `{ "user_id": "..." }`
/// and returns `{ "access_token": "...", "expires_in": 86400 }`. This avoids
/// shipping a long-lived token inside the app bundle.
///
/// The minted token is cached in memory; `DeviceManager`/`PlaudAPIService` read
/// it via their `userAccessToken` accessors (falling back to the bundled value).
final class TokenManager {

    static let shared = TokenManager()

    private let session = URLSession.shared

    /// In-memory cache of the most recently minted user access token.
    private(set) var currentToken: String?

    private init() {}

    /// Backend base URL configured via `UserTokenBackendURL` (Info.plist).
    ///
    /// The config value is a bare host (e.g. `your-backend.vercel.app`) — `//`
    /// can't be used in an xcconfig value because it starts a comment. Any scheme
    /// the user does include is stripped, then `https://` is prepended and any
    /// trailing slash trimmed.
    var backendURL: String {
        var raw = (Bundle.main.object(forInfoDictionaryKey: "UserTokenBackendURL") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        if let range = raw.range(of: "://") {
            raw = String(raw[range.upperBound...])
        }
        if raw.hasSuffix("/") { raw = String(raw.dropLast()) }
        return raw.isEmpty ? "" : "https://\(raw)"
    }

    /// Whether a real backend URL is configured (not empty / placeholder).
    var isConfigured: Bool {
        let base = backendURL
        return !base.isEmpty && base != "https://YOUR_BACKEND_HERE"
    }

    /// POST { user_id } to the backend, cache and return the minted access token.
    func fetchUserToken(userId: String, completion: @escaping (Result<String, Error>) -> Void) {
        let base = backendURL
        guard isConfigured, let url = URL(string: "\(base)/api/user-token") else {
            print("[TokenManager] ❌ user token NOT procured: USER_TOKEN_BACKEND_URL is not configured")
            completion(.failure(APIError.missingCredentials(
                "USER_TOKEN_BACKEND_URL is not configured. Set it in PartnerConfig.local.xcconfig.")))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["user_id": userId])

        #if DEBUG
        print("[TokenManager] >>> POST \(url.absoluteString) user_id=\(userId)")
        #endif

        session.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                print("[TokenManager] ❌ user token NOT procured (user_id=\(userId)): network error: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            guard let data = data else {
                print("[TokenManager] ❌ user token NOT procured (user_id=\(userId)): empty response")
                completion(.failure(APIError.noData))
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("[TokenManager] ❌ user token NOT procured (user_id=\(userId)): HTTP \(statusCode)")
                #if DEBUG
                print("[TokenManager] <<< body: \(body)")
                #endif
                completion(.failure(APIError.httpError(statusCode, body)))
                return
            }
            do {
                let decoded = try JSONDecoder().decode(UserTokenResponse.self, from: data)
                self?.currentToken = decoded.accessToken
                print("[TokenManager] ✅ user token procured (user_id=\(userId), expires_in=\(decoded.expiresIn ?? 0))")
                completion(.success(decoded.accessToken))
            } catch {
                print("[TokenManager] ❌ user token NOT procured (user_id=\(userId)): decode error: \(error.localizedDescription)")
                completion(.failure(error))
            }
        }.resume()
    }
}

/// Response shape from `POST /api/user-token`.
private struct UserTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}
