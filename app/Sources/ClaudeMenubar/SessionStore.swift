import Foundation
import Combine

/// Watches ~/.claude/menubar/sessions for JSON state files and exposes them.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [SessionState] = []
    /// Refresh 버튼 클릭 시 true → 모든 recap generation 완료 후 false.
    /// UI 가 이 값을 보고 버튼을 spinner 로 바꾸고 disable.
    @Published private(set) var isRefreshing: Bool = false

    private let dirURL: URL
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var pollTask: Task<Void, Never>?
    /// 알림 발화 대상 검출용 — 이전 reload 의 session→state 매핑.
    private var prevStates: [String: SessionStatus] = [:]
    /// 앱 시작 직후 첫 reload 는 알림 skip (기존 waiting 세션 spam 방지).
    private var firstReloadDone = false

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.dirURL = home
            .appendingPathComponent(".claude")
            .appendingPathComponent("menubar")
            .appendingPathComponent("sessions")
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        startWatching()
        reload()
        runDiscovery()
        triggerRecaps()
        // Lightweight poll to catch in-file updates and to bootstrap sessions
        // started before the menubar app launched. We use a MainActor Task
        // sleep-loop (instead of Timer) so the weak-self capture is async-safe
        // and survives Swift 6 strict concurrency.
        self.pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self else { return }
                self.reload()
                self.runDiscovery()
                self.triggerRecaps()
            }
        }
    }

    private func triggerRecaps() {
        for s in sessions {
            ClaudeRecapGenerator.shared.generateIfNeeded(for: s, store: self)
        }
    }

    /// Refresh 버튼용. AFK·hash 가드 우회하고 모든 세션 recap 즉시 재생성.
    /// 호출 동안 `isRefreshing = true` 로 UI 가 spinner/disabled 상태 유지.
    func forceRecapAll() {
        if isRefreshing { return }   // 이미 진행 중이면 무시 (중복 호출 방지)
        reload()
        isRefreshing = true
        for s in sessions {
            ClaudeRecapGenerator.shared.generateIfNeeded(for: s, store: self, force: true)
        }
        // generate 들은 background Task 라 동기적으로 완료를 기다릴 수 없음.
        // ClaudeRecapGenerator 의 in-flight 가 다 빠질 때까지 폴링.
        Task { @MainActor [weak self] in
            // 첫 spawn 들이 모두 inFlight 에 등록될 시간을 약간 줌.
            try? await Task.sleep(nanoseconds: 200_000_000)
            // 최대 60초 안전망 (claude CLI 호출이 5-10초 × 세션수).
            let deadline = Date().addingTimeInterval(60)
            while ClaudeRecapGenerator.shared.hasInFlight() && Date() < deadline {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            self?.isRefreshing = false
        }
    }

    deinit {
        dispatchSource?.cancel()
        if dirFD >= 0 { close(dirFD) }
        pollTask?.cancel()
    }

    private func startWatching() {
        dirFD = open(dirURL.path, O_EVTONLY)
        guard dirFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            self?.reload()
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 { close(fd) }
            self?.dirFD = -1
        }
        src.resume()
        self.dispatchSource = src
    }

    func reload() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            self.sessions = []
            return
        }
        let decoder = JSONDecoder()
        var loaded: [SessionState] = []
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let s = try? decoder.decode(SessionState.self, from: data) else {
                continue
            }
            // Stale cleanup: pid no longer alive AND not "done"
            if let pid = s.pid, !processAlive(pid: pid), s.state != .done {
                try? fm.removeItem(at: url)
                continue
            }
            loaded.append(s)
        }
        // Sort by pid desc (immutable per session). Avoids row reordering whenever
        // a session's transcript ticks or its recap finishes generating.
        loaded.sort { ($0.pid ?? 0) > ($1.pid ?? 0) }

        // Detect transitions into `waiting` (action needed) and notify the user.
        // 첫 reload 는 skip — 부팅 직후 이미 waiting 인 세션은 사용자가 이미 인지.
        if firstReloadDone {
            for new in loaded where new.state == .waiting {
                if prevStates[new.id] != .waiting {
                    Notifier.send(for: new)
                }
            }
        }
        prevStates = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0.state) })
        firstReloadDone = true

        self.sessions = loaded
    }

    private func processAlive(pid: Int) -> Bool {
        // kill(pid, 0) returns 0 if process exists and we have permission.
        // ESRCH means it's gone.
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    // MARK: - Discovery (backfill for sessions started before app launch)

    private func runDiscovery() {
        Task.detached(priority: .utility) {
            let discovered = SessionDiscovery.discover()
            await MainActor.run { [weak self] in
                self?.applyDiscovered(discovered)
            }
        }
    }

    private func applyDiscovered(_ discovered: [DiscoveredSession]) {
        let fm = FileManager.default
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let home = fm.homeDirectoryForCurrentUser.path
        var didWrite = false
        for d in discovered {
            let path = dirURL.appendingPathComponent("\(d.claudeSessionID).json")
            if fm.fileExists(atPath: path.path) {
                // Hook 이 이미 만든 상태 파일이 더 정확. 건드리지 않습니다.
                continue
            }
            var dict: [String: Any] = [
                "claude_session_id": d.claudeSessionID,
                "cwd": d.cwd,
                "cwd_display": tildify(d.cwd, home: home),
                "transcript_path": d.transcriptPath,
                "state": "running",
                "current_task": Self.truncate(d.lastMessage, limit: 80) ?? t(.discoveredFallback),
                "pid": d.pid,
                "updated_at": isoFormatter.string(from: Date()),
            ]
            if let b = d.branch { dict["branch"] = b }
            if let it = d.itermSessionID { dict["iterm_session_id"] = it }
            guard let data = try? JSONSerialization.data(
                withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]
            ) else { continue }
            let tmp = path.appendingPathExtension("tmp")
            try? data.write(to: tmp, options: .atomic)
            do {
                try fm.moveItem(at: tmp, to: path)
                didWrite = true
            } catch {
                try? fm.removeItem(at: tmp)
            }
        }
        if didWrite { reload() }
    }

    private func tildify(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private static func truncate(_ s: String?, limit: Int) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let firstLine = s.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? s
        if firstLine.count > limit {
            return String(firstLine.prefix(limit - 1)) + "…"
        }
        return firstLine
    }

    // MARK: - State patching (menubar-owned fields)
    //
    // Hook 과 같은 파일을 patch 하지만 다른 키만 건드립니다. atomic rename 으로
    // tearing 은 막지만, hook 과 동시 patch 시 last-writer-wins 가능성 있습니다.
    // 동시성 충돌은 드물고 영향도 작아 (last_viewed_at 한 두 번 늦게 반영) 일단
    // 단순한 read-modify-write 를 채택합니다.

    func markViewed(_ session: SessionState) {
        let now = Self.isoNow()
        patchState(sessionID: session.id) { dict in
            dict["last_viewed_at"] = now
        }
    }

    func markAllViewed() {
        let now = Self.isoNow()
        for s in sessions {
            patchState(sessionID: s.id) { dict in
                dict["last_viewed_at"] = now
            }
        }
    }

    func saveNote(sessionID: String, note: String) {
        patchState(sessionID: sessionID) { dict in
            if note.isEmpty {
                dict.removeValue(forKey: "next_step_note")
            } else {
                dict["next_step_note"] = note
            }
        }
        reload()
    }

    func saveClaudeRecap(sessionID: String, recap: ClaudeRecap) {
        patchState(sessionID: sessionID) { dict in
            dict["claude_recap"] = [
                "text": recap.text,
                "transcript_hash": recap.transcriptHash,
                "generated_at": recap.generatedAt,
            ]
        }
        reload()
    }

    private func patchState(sessionID: String, mutate: (inout [String: Any]) -> Void) {
        let url = dirURL.appendingPathComponent("\(sessionID).json")
        guard let data = try? Data(contentsOf: url),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        mutate(&dict)
        guard let out = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        // .atomic 옵션이 내부적으로 tmp 작성 → rename 처리해 race 안전.
        try? out.write(to: url, options: .atomic)
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }

    func session(id: String) -> SessionState? {
        sessions.first(where: { $0.id == id })
    }
}
