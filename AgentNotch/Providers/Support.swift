import Foundation
import SQLite3

nonisolated enum JSONDate: Sendable {
    static func parse(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: string)
    }
}

nonisolated enum ProviderJSON: Sendable {
    static func object(_ data: Data) throws -> [String: Any] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UsageProviderError.badResponse("unreadable JSON")
        }
        guard let object = value as? [String: Any] else {
            throw UsageProviderError.badResponse("expected a JSON object")
        }
        return object
    }

    static func double(_ any: Any?) -> Double? {
        if any is NSNull { return nil }
        if let number = any as? NSNumber { return number.doubleValue }
        if let value = any as? Double { return value }
        if let value = any as? Int { return Double(value) }
        if let value = any as? String { return Double(value) }
        return nil
    }

    static func int(_ any: Any?) -> Int? {
        if any is NSNull { return nil }
        if let number = any as? NSNumber { return number.intValue }
        if let value = any as? Int { return value }
        if let value = any as? Double { return Int(value) }
        if let value = any as? String { return Int(value) }
        return nil
    }

    static func capitalised(_ raw: String) -> String {
        guard let first = raw.first else { return raw }
        return first.uppercased() + raw.dropFirst()
    }
}

nonisolated enum ProviderHTTP: Sendable {
    static func get(url: URL, headers: [String: String], authFailed: String) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("AgentNotch/1.0", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageProviderError.badResponse("request failed")
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageProviderError.badResponse("missing HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401, 403:
            throw UsageProviderError.needsAuth(authFailed)
        default:
            throw UsageProviderError.badResponse("HTTP \(http.statusCode)")
        }
    }
}

nonisolated enum ReadonlySQLite: Sendable {
    static func queryColumn(path: String, sql: String, bind: String? = nil) -> [String]? {
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }
        let allowed = CharacterSet.urlPathAllowed
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        let uri = "file:\(encoded)?immutable=1"
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
        let opened = sqlite3_open_v2(uri, &db, flags, nil)
        guard opened == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        if let bind {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(stmt, 1, bind, -1, transient) == SQLITE_OK else { return nil }
        }

        var rows: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 0) {
                rows.append(String(cString: cString))
            }
        }
        return rows
    }
}
