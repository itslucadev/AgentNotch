import Darwin
import Foundation

nonisolated enum ClaudeSessionMonitor: Sendable {
    static func liveSessions() -> [AgentSession] {
        let directory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".claude/sessions", isDirectory: true)
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        } catch {
            return []
        }

        var sessions: [AgentSession] = []
        for file in files where file.pathExtension == "json" {
            if let session = readSession(at: file) {
                sessions.append(session)
            }
        }
        sessions.sort { $0.startedAt > $1.startedAt }
        return sessions
    }

    private static func readSession(at url: URL) -> AgentSession? {
        guard let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard let pid = ProviderJSON.int(json["pid"]), pid > 0, pid <= Int(Int32.max),
            isAlive(pid_t(pid)),
            let sessionId = json["sessionId"] as? String, !sessionId.isEmpty,
            let cwd = json["cwd"] as? String,
            let startedMs = ProviderJSON.double(json["startedAt"])
        else { return nil }

        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folder
        let status = json["status"] as? String ?? ""
        let activity = AgentSession.Activity(rawValue: status) ?? .idle
        return AgentSession(
            id: sessionId,
            name: name,
            detail: folder,
            activity: activity,
            startedAt: Date(timeIntervalSince1970: startedMs / 1000)
        )
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
