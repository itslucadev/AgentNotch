import Foundation

nonisolated struct CursorLocalProvider: UsageProvider {
    var id: ProviderID { .cursor }

    private static let usageURL = URL(string: "https://cursor.com/api/usage-summary")!
    private static let cookieAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    func fetch() async throws -> ProviderSnapshot {
        let db = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
            )
            .path
        let token = ReadonlySQLite.queryColumn(
            path: db,
            sql: "SELECT value FROM ItemTable WHERE key = ?",
            bind: "cursorAuth/accessToken"
        )?.first
        guard let token, !token.isEmpty else {
            throw UsageProviderError.needsAuth("Sign in to Cursor in the editor")
        }

        let payload = try jwtPayload(token)
        if let exp = ProviderJSON.double(payload["exp"]),
            Date(timeIntervalSince1970: exp) < Date()
        {
            throw UsageProviderError.needsAuth("Sign in to Cursor in the editor")
        }
        guard let sub = payload["sub"] as? String, !sub.isEmpty else {
            throw UsageProviderError.needsAuth("Sign in to Cursor in the editor")
        }
        let userId = sub.split(separator: "|").last.map(String.init) ?? sub
        guard !userId.isEmpty else {
            throw UsageProviderError.needsAuth("Sign in to Cursor in the editor")
        }

        let cookieValue = "\(userId)::\(token)"
        let encoded =
            cookieValue.addingPercentEncoding(withAllowedCharacters: Self.cookieAllowed)
            ?? cookieValue
        let data = try await ProviderHTTP.get(
            url: Self.usageURL,
            headers: ["Cookie": "WorkosCursorSessionToken=\(encoded)"],
            authFailed: "Sign in to Cursor in the editor"
        )
        let root = try ProviderJSON.object(data)
        let email = ReadonlySQLite.queryColumn(
            path: db,
            sql: "SELECT value FROM ItemTable WHERE key = ?",
            bind: "cursorAuth/cachedEmail"
        )?.first
        let storedPlan = ReadonlySQLite.queryColumn(
            path: db,
            sql: "SELECT value FROM ItemTable WHERE key = ?",
            bind: "cursorAuth/stripeMembershipType"
        )?.first
        return try snapshot(from: root, email: email, storedPlan: storedPlan)
    }

    private func jwtPayload(_ token: String) throws -> [String: Any] {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            throw UsageProviderError.needsAuth("Sign in to Cursor in the editor")
        }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - payload.count % 4) % 4
        payload += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: payload),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw UsageProviderError.needsAuth("Sign in to Cursor in the editor")
        }
        return json
    }

    private func snapshot(
        from root: [String: Any],
        email: String?,
        storedPlan: String?
    ) throws -> ProviderSnapshot {
        guard let usage = root["individualUsage"] as? [String: Any] else {
            throw UsageProviderError.badResponse("missing individualUsage")
        }
        let plan = usage["plan"] as? [String: Any] ?? [:]
        let onDemand = usage["onDemand"] as? [String: Any] ?? [:]
        let resets = (root["billingCycleEnd"] as? String).flatMap(JSONDate.parse)
        let included = ProviderJSON.double(plan["totalPercentUsed"]) ?? 0
        let api = ProviderJSON.double(plan["apiPercentUsed"]) ?? 0
        let used = ProviderJSON.double(onDemand["used"]) ?? 0
        let limit = ProviderJSON.double(onDemand["limit"]) ?? 0
        let onDemandFraction = limit > 0 ? used / limit : 0
        let membership = (root["membershipType"] as? String) ?? storedPlan
        let account = email.flatMap { $0.isEmpty ? nil : $0 }
        return ProviderSnapshot(
            id: .cursor,
            account: account,
            plan: membership.map(Self.planName),
            windows: [
                LimitWindow(
                    id: "included",
                    label: "Included usage",
                    usedFraction: included / 100,
                    resetsAt: resets
                ),
                LimitWindow(
                    id: "api",
                    label: "API usage",
                    usedFraction: api / 100,
                    resetsAt: resets
                ),
                LimitWindow(
                    id: "on_demand",
                    label: "On demand",
                    usedFraction: onDemandFraction,
                    resetsAt: resets
                ),
            ],
            fetchedAt: Date()
        )
    }

    private static func planName(_ raw: String) -> String {
        switch raw {
        case "pro_plus": "Pro+"
        case "pro": "Pro"
        case "ultra": "Ultra"
        case "free": "Free"
        case "enterprise": "Enterprise"
        default: ProviderJSON.capitalised(raw)
        }
    }
}
