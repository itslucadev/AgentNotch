import Foundation
import os

nonisolated struct ClaudeOAuthSession: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: TimeInterval
    var email: String?

    var expires: Date { Date(timeIntervalSince1970: expiresAt) }
    var needsRefresh: Bool { expires.addingTimeInterval(-300) <= Date() }

    /// Claude Code stores `expiresAt` in milliseconds. Agent Notch uses seconds.
    static func fromClaudeCodeBlob(_ data: Data) -> ClaudeOAuthSession? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = json["claudeAiOauth"] as? [String: Any],
            let accessToken = oauth["accessToken"] as? String, !accessToken.isEmpty,
            let expiresAtRaw = ProviderJSON.double(oauth["expiresAt"])
        else { return nil }
        let refresh = (oauth["refreshToken"] as? String) ?? ""
        let expiresAt = expiresAtRaw >= 1_000_000_000_000 ? expiresAtRaw / 1000 : expiresAtRaw
        return ClaudeOAuthSession(
            accessToken: accessToken,
            refreshToken: refresh,
            expiresAt: expiresAt,
            email: nil
        )
    }
}

nonisolated enum ClaudeOAuthStore {
    static let service = "app.lucabecker.AgentNotch.claude-oauth"
    static let account = "claude"
    static let claudeCodeService = "Claude Code-credentials"
    private static let skipImportKey = "skipClaudeCodeImport"
    private static let gate = NSLock()
    private static let cache = OSAllocatedUnfairLock<Cache>(initialState: .cold)

    private enum Cache: Sendable {
        case cold
        case loaded(ClaudeOAuthSession?)
    }

    static var skipClaudeCodeImport: Bool {
        get { UserDefaults.standard.bool(forKey: skipImportKey) }
        set { UserDefaults.standard.set(newValue, forKey: skipImportKey) }
    }

    static func load() throws -> ClaudeOAuthSession? {
        gate.lock()
        defer { gate.unlock() }
        if case .loaded(let session) = cache.withLock({ $0 }) {
            return session
        }
        do {
            let session = try read()
            cache.withLock { $0 = .loaded(session) }
            return session
        } catch {
            cache.withLock { $0 = .loaded(nil) }
            throw error
        }
    }

    static func save(_ session: ClaudeOAuthSession) throws {
        removeLegacyFileCache()
        let data = try JSONEncoder().encode(session)
        try Keychain.set(data, service: service, account: account)
        cache.withLock { $0 = .loaded(session) }
    }

    static func clear() {
        cache.withLock { $0 = .loaded(nil) }
        removeLegacyFileCache()
        Keychain.delete(service: service, account: account)
    }

    private static func read() throws -> ClaudeOAuthSession? {
        removeLegacyFileCache()
        if let data = try Keychain.data(service: service, account: account),
            let session = try? JSONDecoder().decode(ClaudeOAuthSession.self, from: data)
        {
            return session
        }
        if skipClaudeCodeImport { return nil }
        guard
            let data = try Keychain.data(
                service: claudeCodeService, dataProtection: false),
            let session = ClaudeOAuthSession.fromClaudeCodeBlob(data)
        else { return nil }
        try? save(session)
        return session
    }

    /// Previous builds copied Claude Code's blob into Application Support. Delete it.
    static func removeLegacyFileCache() {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentNotch", isDirectory: true)
            .appendingPathComponent("claude-oauth.json")
        try? FileManager.default.removeItem(at: url)
    }
}

nonisolated enum ClaudeOAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeEndpoint = URL(string: "https://claude.ai/oauth/authorize")!
    static let tokenEndpoint = URL(string: "https://api.anthropic.com/v1/oauth/token")!
    static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let redirectURI = "http://localhost:54545/callback"
    static let callbackPort: UInt16 = 54545
    static let scopes = [
        "org:create_api_key",
        "user:profile",
        "user:inference",
        "user:sessions:claude_code",
        "user:mcp_servers",
        "user:file_upload",
    ].joined(separator: " ")

    static func authorizeURL(challenge: String, state: String) -> URL {
        var parts = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code", value: "true"),
        ]
        return parts.url!
    }

    static func parseCallback(_ url: URL, expectedState: String) throws -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw ClaudeLoginError.badCallback
        }
        let query = Dictionary(
            uniqueKeysWithValues: items.compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name, value)
            })
        if let error = query["error"] {
            if error == "access_denied" { throw ClaudeLoginError.denied }
            throw ClaudeLoginError.badCallback
        }
        guard let code = query["code"], !code.isEmpty else { throw ClaudeLoginError.badCallback }
        guard query["state"] == expectedState else { throw ClaudeLoginError.badCallback }
        return code
    }

    static func parseRequestLine(_ line: String, expectedState: String) throws -> String {
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { throw ClaudeLoginError.badCallback }
        guard let url = URL(string: "http://localhost\(parts[1])") else { throw ClaudeLoginError.badCallback }
        return try parseCallback(url, expectedState: expectedState)
    }

    static func session(fromTokenResponse body: [String: Any], previousRefresh: String? = nil) throws
        -> ClaudeOAuthSession
    {
        guard let access = body["access_token"] as? String, !access.isEmpty,
            let expiresIn = ProviderJSON.double(body["expires_in"])
        else {
            throw ClaudeLoginError.tokenExchange
        }
        let refresh =
            (body["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? previousRefresh
            ?? ""
        let account = body["account"] as? [String: Any]
        let email = account?["email_address"] as? String
        return ClaudeOAuthSession(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().timeIntervalSince1970 + expiresIn,
            email: email.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

enum ClaudeLoginError: Error, LocalizedError, Equatable {
    case portInUse
    case cancelled
    case denied
    case timeout
    case badCallback
    case tokenExchange

    var errorDescription: String? {
        switch self {
        case .portInUse:
            "Port 54545 is in use. Close a Claude login in another app and try again."
        case .cancelled:
            "Sign in was cancelled."
        case .denied:
            "Claude sign in was denied."
        case .timeout:
            "Sign in timed out. Try again."
        case .badCallback:
            "Claude returned an unusable sign-in callback."
        case .tokenExchange:
            "Claude did not issue a token."
        }
    }
}
