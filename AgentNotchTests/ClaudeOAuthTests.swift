import Foundation
import Testing

@testable import AgentNotch

struct ClaudeOAuthTests {
    @Test func authorizeURLIncludesPKCELoopbackAndCodeFlag() {
        let url = ClaudeOAuth.authorizeURL(challenge: "challenge_abc", state: "state_xyz")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
        #expect(url.host == "claude.ai")
        #expect(query["client_id"] == ClaudeOAuth.clientID)
        #expect(query["response_type"] == "code")
        #expect(query["redirect_uri"] == ClaudeOAuth.redirectURI)
        #expect(query["code_challenge"] == "challenge_abc")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["state"] == "state_xyz")
        #expect(query["code"] == "true")
        #expect(query["scope"]?.contains("user:inference") == true)
    }

    @Test func parseCallbackReadsCodeWhenStateMatches() throws {
        let url = URL(string: "http://localhost:54545/callback?code=auth_code&state=abc")!
        #expect(try ClaudeOAuth.parseCallback(url, expectedState: "abc") == "auth_code")
    }

    @Test func parseCallbackRejectsMismatchedState() {
        let url = URL(string: "http://localhost:54545/callback?code=auth_code&state=nope")!
        #expect(throws: ClaudeLoginError.self) {
            try ClaudeOAuth.parseCallback(url, expectedState: "abc")
        }
    }

    @Test func parseCallbackMapsAccessDenied() {
        let url = URL(string: "http://localhost:54545/callback?error=access_denied&state=abc")!
        #expect(throws: ClaudeLoginError.denied) {
            try ClaudeOAuth.parseCallback(url, expectedState: "abc")
        }
    }

    @Test func parseRequestLineReadsTheFirstHTTPLine() throws {
        let line = "GET /callback?code=auth_code&state=abc HTTP/1.1"
        #expect(try ClaudeOAuth.parseRequestLine(line, expectedState: "abc") == "auth_code")
    }

    @Test func tokenResponseMapsAccessRefreshAndExpiry() throws {
        let before = Date().timeIntervalSince1970
        let session = try ClaudeOAuth.session(
            fromTokenResponse: [
                "access_token": "sk-ant-oat-1",
                "refresh_token": "sk-ant-ort-1",
                "expires_in": 28800,
                "account": ["email_address": "luca@example.com"],
            ]
        )
        #expect(session.accessToken == "sk-ant-oat-1")
        #expect(session.refreshToken == "sk-ant-ort-1")
        #expect(session.email == "luca@example.com")
        #expect(session.expiresAt >= before + 28800 - 1)
        #expect(session.expiresAt <= before + 28800 + 1)
    }

    @Test func tokenResponseKeepsPreviousRefreshWhenOmitted() throws {
        let session = try ClaudeOAuth.session(
            fromTokenResponse: [
                "access_token": "sk-ant-oat-2",
                "expires_in": 60,
            ],
            previousRefresh: "keep-me"
        )
        #expect(session.refreshToken == "keep-me")
    }

    @Test func pkceVerifierAndChallengeAreUnpaddedBase64URL() {
        let pair = PKCE.generate()
        #expect(pair.verifier.contains("+") == false)
        #expect(pair.verifier.contains("/") == false)
        #expect(pair.verifier.contains("=") == false)
        #expect(pair.challenge.contains("+") == false)
        #expect(pair.challenge.contains("/") == false)
        #expect(pair.challenge.contains("=") == false)
        #expect(pair.challenge.count == 43)
    }

    @Test func sessionJSONRoundTrips() throws {
        let session = ClaudeOAuthSession(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: 1_800_000_000,
            email: "luca@example.com"
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(ClaudeOAuthSession.self, from: data)
        #expect(decoded == session)
    }
}
