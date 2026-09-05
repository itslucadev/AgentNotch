import Foundation
import Testing

@testable import AgentNotch

struct ProviderUsageTests {
    @Test func claudeCodeBlobConvertsMillisecondExpiry() throws {
        let blob = Data(
            """
            {"claudeAiOauth":{"accessToken":"tok","refreshToken":"ref","expiresAt":1788542453069}}
            """.utf8)
        let session = try #require(ClaudeOAuthSession.fromClaudeCodeBlob(blob))
        #expect(session.accessToken == "tok")
        #expect(session.refreshToken == "ref")
        #expect(abs(session.expiresAt - 1_788_542_453.069) < 0.01)
    }

    @Test func claudeCodeBlobRejectsMissingToken() {
        let blob = Data(#"{"claudeAiOauth":{"expiresAt":1788542453069}}"#.utf8)
        #expect(ClaudeOAuthSession.fromClaudeCodeBlob(blob) == nil)
    }

    @Test func claudeUsageJSONBuildsSessionAndWeeklyWindows() {
        let json: [String: Any] = [
            "five_hour": [
                "utilization": 2.0,
                "resets_at": "2026-09-04T12:09:59.972355+00:00",
            ],
            "seven_day": [
                "utilization": 18.0,
                "resets_at": "2026-09-07T19:59:59.972383+00:00",
            ],
            "limits": [
                [
                    "kind": "weekly_scoped",
                    "percent": 5,
                    "scope": ["model": ["display_name": "Sonnet"]],
                ]
            ],
        ]
        let windows = ClaudeOAuthProvider().windows(from: json)
        #expect(windows.map(\.id) == ["session", "weekly", "weekly_sonnet"])
        #expect(windows[0].usedFraction == 0.02)
        #expect(windows[1].usedFraction == 0.18)
        #expect(windows[2].usedFraction == 0.05)
        #expect(windows[2].label == "Sonnet")
    }

    @Test func claudeUsageJSONWithoutBucketsIsEmpty() {
        #expect(ClaudeOAuthProvider().windows(from: [:]).isEmpty)
    }

    @Test func codexRateLimitsBuildPrimaryAndSecondaryWindows() throws {
        let limits: [String: Any] = [
            "plan_type": "plus",
            "primary": [
                "used_percent": 1.0,
                "window_minutes": 300,
                "resets_at": 1_788_040_219.0,
            ],
            "secondary": [
                "used_percent": 0.0,
                "window_minutes": 10_080,
                "resets_at": 1_788_627_019.0,
            ],
        ]
        let snapshot = try CodexLocalProvider().snapshot(from: limits)
        #expect(snapshot.id == .codex)
        #expect(snapshot.plan == "Plus")
        #expect(snapshot.windows.map(\.label) == ["Current session", "Weekly limit"])
        #expect(snapshot.windows[0].usedFraction == 0.01)
        #expect(snapshot.windows[1].usedFraction == 0)
    }

    @Test func codexAcceptsWindowDurationMins() {
        let window = CodexLocalProvider().window(
            id: "primary",
            from: ["used_percent": 7.0, "window_duration_mins": 10_080]
        )
        #expect(window?.label == "Weekly limit")
        #expect(window?.usedFraction == 0.07)
    }

    @Test func codexFindsRateLimitsInJsonl() {
        let line = """
            {"payload":{"type":"token_count","rate_limits":{"plan_type":"plus","primary":{"used_percent":3,"window_minutes":300}}}}
            """
        let limits = CodexLocalProvider().rateLimits(in: Data((line + "\n").utf8))
        #expect(limits?["plan_type"] as? String == "plus")
    }

    @Test func authTokenReadsAccessTokenOrApiKey() {
        let provider = CodexLocalProvider()
        #expect(
            provider.authToken(in: Data(#"{"tokens":{"access_token":"aaa"}}"#.utf8)) == "aaa")
        #expect(provider.authToken(in: Data(#"{"OPENAI_API_KEY":"sk"}"#.utf8)) == "sk")
        #expect(provider.authToken(in: Data("{}".utf8)) == nil)
    }

    @Test func codexLiveUsageJSONBuildsWindows() throws {
        let json: [String: Any] = [
            "plan_type": "plus",
            "rate_limit": [
                "allowed": true,
                "primary_window": [
                    "used_percent": 12,
                    "limit_window_seconds": 18_000,
                    "reset_at": 2_000_000_000,
                ],
                "secondary_window": [
                    "used_percent": 4,
                    "limit_window_seconds": 604_800,
                    "reset_at": 2_000_100_000,
                ],
            ],
        ]
        let snapshot = try CodexLocalProvider().snapshot(from: json)
        #expect(snapshot.plan == "Plus")
        #expect(snapshot.windows.map(\.label) == ["Current session", "Weekly limit"])
        #expect(snapshot.windows[0].usedFraction == 0.12)
        #expect(snapshot.windows[1].usedFraction == 0.04)
    }

    @Test func authAccountIDReadsNestedAccount() {
        let blob = Data(#"{"tokens":{"access_token":"aaa","account_id":"acct_1"}}"#.utf8)
        #expect(CodexLocalProvider().authAccountID(in: blob) == "acct_1")
    }

}
