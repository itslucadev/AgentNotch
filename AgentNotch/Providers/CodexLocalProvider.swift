import Foundation

nonisolated struct CodexLocalProvider: UsageProvider {
    var id: ProviderID { .codex }

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    func fetch() async throws -> ProviderSnapshot {
        if let live = await liveSnapshot() {
            return live
        }
        return try snapshotFromRollouts()
    }

    func liveSnapshot() async -> ProviderSnapshot? {
        guard let blob = authBlob(), let token = authToken(in: blob) else { return nil }
        var headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
        ]
        if let accountID = authAccountID(in: blob) {
            headers["chatgpt-account-id"] = accountID
        }
        do {
            let data = try await ProviderHTTP.get(
                url: Self.usageURL,
                headers: headers,
                authFailed: "Sign in to Codex to read your usage"
            )
            return try snapshot(from: try ProviderJSON.object(data))
        } catch {
            return nil
        }
    }

    func snapshotFromRollouts() throws -> ProviderSnapshot {
        let candidates = rolloutPaths()
        guard !candidates.isEmpty else {
            if hasAuth() {
                throw UsageProviderError.unavailable("Codex has not recorded a usage snapshot yet")
            }
            throw UsageProviderError.needsAuth("Sign in to Codex to read your usage")
        }

        var sawReadable = false
        var sawUnreadable = false
        for path in candidates {
            guard let data = tail(path) else {
                sawUnreadable = true
                continue
            }
            sawReadable = true
            if let limits = rateLimits(in: data) {
                return try snapshot(from: limits)
            }
        }
        if !sawReadable && sawUnreadable {
            throw UsageProviderError.unavailable("Codex's rollout could not be read")
        }
        if hasAuth() {
            throw UsageProviderError.unavailable("Codex has not recorded a usage snapshot yet")
        }
        throw UsageProviderError.needsAuth("Sign in to Codex to read your usage")
    }

    func hasAuth() -> Bool { authToken(in: authBlob()) != nil }

    func authBlob() -> Data? {
        if let data = authFileData() { return data }
        return try? Keychain.data(service: "Codex Auth", dataProtection: false)
    }

    func authFileData() -> Data? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/auth.json")
        return try? Data(contentsOf: url)
    }

    func authToken(in data: Data?) -> String? {
        guard let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let tokens = json["tokens"] as? [String: Any],
            let token = tokens["access_token"] as? String, !token.isEmpty
        {
            return token
        }
        if let token = json["OPENAI_API_KEY"] as? String, !token.isEmpty {
            return token
        }
        return nil
    }

    func authAccountID(in data: Data?) -> String? {
        guard let data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = json["tokens"] as? [String: Any],
            let id = tokens["account_id"] as? String, !id.isEmpty
        else { return nil }
        return id
    }

    private func rolloutPaths() -> [String] {
        let db = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/state_5.sqlite").path
        if let rows = ReadonlySQLite.queryColumn(
            path: db,
            sql: "SELECT rollout_path FROM threads ORDER BY updated_at DESC LIMIT 20"
        ), !rows.isEmpty {
            return rows
        }
        return globRollouts()
    }

    private func globRollouts() -> [String] {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        var matches: [(String, Date)] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            let date =
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            matches.append((url.path, date))
        }
        matches.sort { $0.1 > $1.1 }
        return matches.map(\.0)
    }

    private func tail(_ path: String, bytes: Int = 256 * 1024) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let offset: UInt64 = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        do {
            try handle.seek(toOffset: offset)
            return try handle.readToEnd()
        } catch {
            return nil
        }
    }

    func rateLimits(in data: Data) -> [String: Any]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.reversed() where line.contains("\"rate_limits\"") {
            guard let lineData = line.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: lineData),
                let found = firstRateLimits(json)
            else { continue }
            return found
        }
        return nil
    }

    private func firstRateLimits(_ value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if let nested = dict["rate_limits"] as? [String: Any] {
                return nested
            }
            for child in dict.values {
                if let found = firstRateLimits(child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = firstRateLimits(child) { return found }
            }
        }
        return nil
    }

    func snapshot(from limits: [String: Any]) throws -> ProviderSnapshot {
        let nested = limits["rate_limit"] as? [String: Any] ?? limits
        var windows: [LimitWindow] = []
        let primary = nested["primary_window"] ?? nested["primary"] ?? limits["primary"]
        let secondary = nested["secondary_window"] ?? nested["secondary"] ?? limits["secondary"]
        if let window = window(id: "primary", from: primary) {
            windows.append(window)
        }
        if let window = window(id: "secondary", from: secondary) {
            windows.append(window)
        }
        guard !windows.isEmpty else {
            throw UsageProviderError.unavailable("Codex reported no usage windows")
        }
        let plan = ((limits["plan_type"] as? String) ?? (nested["plan_type"] as? String))
            .flatMap { $0.isEmpty ? nil : $0 }
        return ProviderSnapshot(
            id: .codex,
            account: nil,
            plan: plan.map(ProviderJSON.capitalised),
            windows: windows,
            fetchedAt: Date()
        )
    }

    func window(id: String, from raw: Any?) -> LimitWindow? {
        guard let object = raw as? [String: Any],
            let used = ProviderJSON.double(object["used_percent"])
        else { return nil }
        let minutes =
            ProviderJSON.int(object["window_minutes"])
            ?? ProviderJSON.int(object["window_duration_mins"])
            ?? ProviderJSON.int(object["limit_window_seconds"]).map { $0 / 60 }
        guard let minutes else { return nil }
        let resetRaw = ProviderJSON.double(object["resets_at"]) ?? ProviderJSON.double(object["reset_at"])
        let resets = resetRaw.map { Date(timeIntervalSince1970: $0) }
        return LimitWindow(
            id: id,
            label: label(minutes: minutes),
            usedFraction: used / 100,
            resetsAt: resets
        )
    }

    private func label(minutes: Int) -> String {
        switch minutes {
        case 300: "Current session"
        case 10080: "Weekly limit"
        default:
            if minutes % 1440 == 0 {
                "\(minutes / 1440) day limit"
            } else {
                "\(minutes / 60) hour limit"
            }
        }
    }
}
