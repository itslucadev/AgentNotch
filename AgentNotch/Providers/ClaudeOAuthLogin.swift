import AppKit
import CryptoKit
import Foundation
import Network

nonisolated enum ClaudeOAuthLogin {
    @MainActor
    static func signIn() async throws {
        let pkce = PKCE.generate()
        let state = PKCE.random(bytes: 16)
        let callback = LoopbackCallback(port: ClaudeOAuth.callbackPort, expectedState: state)
        try await callback.start()
        defer { callback.stop() }

        NSWorkspace.shared.open(ClaudeOAuth.authorizeURL(challenge: pkce.challenge, state: state))
        let code = try await callback.waitForCode(timeout: 300)
        var session = try await exchange(code: code, verifier: pkce.verifier, state: state)
        if session.email == nil {
            session.email = await bootstrapEmail(accessToken: session.accessToken)
        }
        try ClaudeOAuthStore.save(session)
    }

    static func refresh(_ session: ClaudeOAuthSession) async throws -> ClaudeOAuthSession {
        guard !session.refreshToken.isEmpty else { throw UsageProviderError.needsAuth(ProviderID.claude.signInHint) }
        var request = URLRequest(url: ClaudeOAuth.tokenEndpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("AgentNotch/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "grant_type": "refresh_token",
                "client_id": ClaudeOAuth.clientID,
                "refresh_token": session.refreshToken,
            ]
        )
        let body = try await postToken(request)
        let next = try ClaudeOAuth.session(fromTokenResponse: body, previousRefresh: session.refreshToken)
        var merged = next
        merged.email = next.email ?? session.email
        try ClaudeOAuthStore.save(merged)
        return merged
    }

    private static func exchange(code: String, verifier: String, state: String) async throws -> ClaudeOAuthSession {
        var request = URLRequest(url: ClaudeOAuth.tokenEndpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "grant_type": "authorization_code",
                "client_id": ClaudeOAuth.clientID,
                "code": code,
                "redirect_uri": ClaudeOAuth.redirectURI,
                "code_verifier": verifier,
                "state": state,
            ]
        )
        let body = try await postToken(request)
        return try ClaudeOAuth.session(fromTokenResponse: body)
    }

    private static func postToken(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClaudeLoginError.tokenExchange
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ClaudeLoginError.tokenExchange
        }
        return json
    }

    private static func bootstrapEmail(accessToken: String) async -> String? {
        var request = URLRequest(
            url: URL(string: "https://api.anthropic.com/api/claude_cli/bootstrap?entrypoint=cli")!,
            timeoutInterval: 20
        )
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let account = json["oauth_account"] as? [String: Any],
            let email = account["account_email"] as? String, !email.isEmpty
        else { return nil }
        return email
    }
}
nonisolated enum PKCE {
    struct Pair: Equatable, Sendable {
        var verifier: String
        var challenge: String
    }

    static func generate() -> Pair {
        let verifier = random(bytes: 32)
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Pair(verifier: verifier, challenge: Data(hash).base64URL)
    }

    static func random(bytes: Int) -> String {
        var raw = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &raw)
        return Data(raw).base64URL
    }
}

extension Data {
    fileprivate nonisolated var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

nonisolated final class LoopbackCallback: @unchecked Sendable {
    private let port: UInt16
    private let expectedState: String
    private let queue = DispatchQueue(label: "app.lucabecker.AgentNotch.oauth")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private let lock = NSLock()

    init(port: UInt16, expectedState: String) {
        self.port = port
        self.expectedState = expectedState
    }

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            throw ClaudeLoginError.portInUse
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            func resumeOnce(_ result: Result<Void, Error>) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumeOnce(.success(()))
                case .failed:
                    resumeOnce(.failure(ClaudeLoginError.portInUse))
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        finish(.failure(ClaudeLoginError.cancelled))
    }

    func waitForCode(timeout: TimeInterval) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.lock.lock()
                    self.continuation = continuation
                    self.lock.unlock()
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                self.finish(.failure(ClaudeLoginError.timeout))
                throw ClaudeLoginError.timeout
            }
            let code = try await group.next()!
            group.cancelAll()
            return code
        }
    }
    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            defer {
                connection.send(
                    content: Self.htmlResponse,
                    isComplete: true,
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    }
                )
            }
            if error != nil || data == nil {
                self.finish(.failure(ClaudeLoginError.badCallback))
                return
            }
            guard let text = String(data: data!, encoding: .utf8),
                let line = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first
            else {
                self.finish(.failure(ClaudeLoginError.badCallback))
                return
            }
            do {
                let code = try ClaudeOAuth.parseRequestLine(String(line), expectedState: self.expectedState)
                self.finish(.success(code))
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    private static let htmlResponse = Data(
        """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Connection: close\r
        \r
        <!doctype html><html><body style="font-family:-apple-system;padding:40px">
        Agent Notch is signed in. You can close this tab.
        </body></html>
        """.utf8
    )
}
