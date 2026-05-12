import Foundation

enum HookInstallStatus: Equatable {
    case notInstalled
    case installed
    /// settings.json 에 일부 event 만 등록되어 있는 상태 (다른 도구와의 충돌이나
    /// 사용자가 부분적으로 지운 경우).
    case partial(missing: [String])

    var summary: String {
        switch self {
        case .notInstalled:        return "not installed"
        case .installed:           return "installed"
        case .partial(let miss):   return "partial (missing: \(miss.joined(separator: ", ")))"
        }
    }
}

enum HookInstallError: LocalizedError {
    case writeFailed(String)
    var errorDescription: String? {
        switch self {
        case .writeFailed(let s): return s
        }
    }
}

enum HookInstaller {
    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "Stop", "Notification", "SessionEnd",
    ]

    static var binDirURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("menubar")
            .appendingPathComponent("bin")
    }
    static var hookFileURL: URL { binDirURL.appendingPathComponent("hook.py") }
    static var signalsFileURL: URL { binDirURL.appendingPathComponent("transcript_signals.py") }
    static var hookPath: String { hookFileURL.path }
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("settings.json")
    }

    // MARK: status

    static func status() -> HookInstallStatus {
        guard let settings = readSettings(),
              let hooks = settings["hooks"] as? [String: Any] else {
            return .notInstalled
        }
        var missing: [String] = []
        for event in events {
            let entries = (hooks[event] as? [[String: Any]]) ?? []
            if !entries.contains(where: isOurMatcher) {
                missing.append(event)
            }
        }
        if missing.isEmpty { return .installed }
        if missing.count == events.count { return .notInstalled }
        return .partial(missing: missing)
    }

    private static func isOurMatcher(_ matcher: [String: Any]) -> Bool {
        let inner = (matcher["hooks"] as? [[String: Any]]) ?? []
        return inner.contains { ($0["command"] as? String) == hookPath }
    }

    // MARK: install / uninstall

    /// Idempotent. hook.py 디스크 내용이 임베드된 것과 다르면 갱신하고,
    /// settings.json 도 누락된 event 가 있으면 패치합니다.
    /// 두 가지 모두 변경 없으면 작업을 건너뜁니다.
    @discardableResult
    static func install() throws -> String {
        let hookChanged = try ensureHookOnDisk()
        let settingsChanged = try ensureSettingsRegistered()
        switch (hookChanged, settingsChanged) {
        case (false, false): return "Already up to date"
        case (true, false):  return "Updated hook.py only"
        case (false, true):  return "Registered hooks in settings.json"
        case (true, true):   return "Wrote hook.py and registered settings.json"
        }
    }

    /// settings.json 에서 우리 hook entry 만 제거합니다. hook.py 파일과 sessions
    /// 디렉터리는 그대로 둡니다.
    @discardableResult
    static func uninstall() throws -> String {
        guard var settings = readSettings(),
              var hooks = settings["hooks"] as? [String: Any] else {
            return "Nothing to uninstall"
        }
        var changed = false
        for event in events {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            let before = entries.count
            entries.removeAll(where: isOurMatcher)
            if entries.count != before { changed = true }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }
        if !changed { return "Nothing to uninstall" }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        try writeSettingsWithBackup(settings)
        return "Removed our hooks from settings.json"
    }

    // MARK: hook.py on disk

    private static func ensureHookOnDisk() throws -> Bool {
        try FileManager.default.createDirectory(at: binDirURL, withIntermediateDirectories: true)
        let changedHook = try writeIfChanged(
            content: EmbeddedHookSource.hookSource,
            to: hookFileURL,
            executable: true
        )
        let changedSignals = try writeIfChanged(
            content: EmbeddedHookSource.transcriptSignalsSource,
            to: signalsFileURL,
            executable: false
        )
        return changedHook || changedSignals
    }

    private static func writeIfChanged(content: String, to url: URL, executable: Bool) throws -> Bool {
        let permissions: NSNumber = executable ? 0o755 : 0o644
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == content {
            try? FileManager.default.setAttributes([.posixPermissions: permissions],
                                                   ofItemAtPath: url.path)
            return false
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: permissions],
                                              ofItemAtPath: url.path)
        return true
    }

    // MARK: settings.json safe merge

    private static func ensureSettingsRegistered() throws -> Bool {
        var settings = readSettings() ?? [:]
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        var changed = false

        for event in events {
            var entries = (hooks[event] as? [[String: Any]]) ?? []
            // 이전에 같은 경로로 등록된 우리 matcher 가 있으면 제거 (idempotent + path 갱신).
            let before = entries.count
            entries.removeAll(where: isOurMatcher)
            let removed = before - entries.count
            entries.append([
                "hooks": [
                    ["type": "command", "command": hookPath]
                ]
            ])
            // removed==1 이고 새로 append 한 게 동일하면 변경 없음.
            if removed != 1 { changed = true }
            hooks[event] = entries
        }

        // 이전 상태와 깊은 비교가 비싸므로, status() 결과로도 변경 여부 보정.
        if case .installed = statusFromHooks(hooks), !changed {
            // 모든 event 가 이미 있었고 우리가 한 일은 같은 matcher 를 다시 끼워넣은 것뿐.
            return false
        }

        settings["hooks"] = hooks
        try writeSettingsWithBackup(settings)
        return true
    }

    private static func statusFromHooks(_ hooks: [String: Any]) -> HookInstallStatus {
        var missing: [String] = []
        for event in events {
            let entries = (hooks[event] as? [[String: Any]]) ?? []
            if !entries.contains(where: isOurMatcher) {
                missing.append(event)
            }
        }
        if missing.isEmpty { return .installed }
        if missing.count == events.count { return .notInstalled }
        return .partial(missing: missing)
    }

    // MARK: file IO

    private static func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func writeSettingsWithBackup(_ obj: [String: Any]) throws {
        let dir = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            let stamp = f.string(from: Date())
            let bakURL = dir.appendingPathComponent("settings.json.bak.\(stamp)")
            try? FileManager.default.copyItem(at: settingsURL, to: bakURL)
        }
        let data = try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsURL, options: .atomic)
    }
}
