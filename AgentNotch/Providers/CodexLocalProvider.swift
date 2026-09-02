import Foundation

nonisolated struct CodexLocalProvider: UsageProvider {
    var id: ProviderID { .codex }

    func fetch() async throws -> ProviderSnapshot {
        try requireAuth()
        let candidates = rolloutPaths()
        guard !candidates.isEmpty else {
            throw UsageProviderError.unavailable("Codex has not recorded a usage snapshot yet")
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
        throw UsageProviderError.unavailable("Codex has not recorded a usage snapshot yet")
    }

    private func requireAuth() throws {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = json["tokens"] as? [String: Any], !tokens.isEmpty,
            let token = tokens["access_token"] as? String, !token.isEmpty
        else {
            throw UsageProviderError.needsAuth("Sign in to Codex to read your usage")
        }
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

    private func rateLimits(in data: Data) -> [String: Any]? {
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

    private func snapshot(from limits: [String: Any]) throws -> ProviderSnapshot {
        var windows: [LimitWindow] = []
        if let window = window(id: "primary", from: limits["primary"]) {
            windows.append(window)
        }
        if let window = window(id: "secondary", from: limits["secondary"]) {
            windows.append(window)
        }
        guard !windows.isEmpty else {
            throw UsageProviderError.unavailable("Codex reported no usage windows")
        }
        let plan = (limits["plan_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ProviderSnapshot(
            id: .codex,
            account: nil,
            plan: plan.map(ProviderJSON.capitalised),
            windows: windows,
            fetchedAt: Date()
        )
    }

    private func window(id: String, from raw: Any?) -> LimitWindow? {
        guard let object = raw as? [String: Any],
            let used = ProviderJSON.double(object["used_percent"]),
            let minutes = ProviderJSON.int(object["window_minutes"])
        else { return nil }
        let resets = ProviderJSON.double(object["resets_at"]).map {
            Date(timeIntervalSince1970: $0)
        }
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
