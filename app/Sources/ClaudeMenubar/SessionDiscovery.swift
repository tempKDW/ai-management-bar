import Foundation

/// 외부에서 본 active Claude Code 세션의 발견 결과.
struct DiscoveredSession {
    let claudeSessionID: String
    let itermSessionID: String?
    let terminalProgram: String?
    let cwd: String
    let branch: String?
    let transcriptPath: String
    let lastMessage: String?
    let pid: Int
}

/// 메뉴바 hook 이 발화하기 전부터 떠 있던 세션도 메뉴바에 표시되도록 합니다.
///
/// 동작:
/// 1. `ps -ax` 로 사용자 소유의 `claude` 프로세스 PID·tty 수집
/// 2. 각 프로세스에서 `ITERM_SESSION_ID` (ps -E) 와 cwd (lsof) 추출
/// 3. `~/.claude/projects/*/<sessionId>.jsonl` 을 스캔해 cwd 별로 가장 최근 transcript 선택
/// 4. process.cwd ↔ transcript.cwd 매칭으로 sessionId·gitBranch·last message 추출
enum SessionDiscovery {

    static func discover() -> [DiscoveredSession] {
        let procs = listClaudeProcesses()
        if procs.isEmpty { return [] }

        // 후보 transcript 를 cwd 별로 그룹핑하고 mtime desc 정렬.
        let transcripts = scanTranscripts()
        var byCwd: [String: [TranscriptInfo]] = [:]
        for t in transcripts {
            guard let c = t.cwd else { continue }
            byCwd[c, default: []].append(t)
        }
        for k in byCwd.keys {
            byCwd[k]?.sort { $0.mtime > $1.mtime }
        }

        // 이미 hook 으로 추적 중인 session·pid 는 discovery 가 끼어들지 않습니다.
        let fm = FileManager.default
        let sessionsDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").appendingPathComponent("menubar")
            .appendingPathComponent("sessions")
        var claimed: Set<String> = []
        var claimedPids: Set<Int> = []
        if let names = try? fm.contentsOfDirectory(atPath: sessionsDir.path) {
            for n in names where n.hasSuffix(".json") {
                claimed.insert(String(n.dropLast(5)))
                let url = sessionsDir.appendingPathComponent(n)
                if let data = try? Data(contentsOf: url),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let pid = obj["pid"] as? Int {
                    claimedPids.insert(pid)
                }
            }
        }

        var results: [DiscoveredSession] = []
        for p in procs {
            if claimedPids.contains(p.pid) { continue }
            guard let cwd = lsofCwd(pid: p.pid),
                  let candidates = byCwd[cwd] else { continue }
            // 해당 cwd 그룹 안에서 아직 등록되지 않은 가장 최근 transcript.
            guard let pick = candidates.first(where: { !claimed.contains($0.sessionId) }) else {
                continue
            }
            claimed.insert(pick.sessionId)
            let iterm = envVar(pid: p.pid, name: "ITERM_SESSION_ID")
            let termProgram = envVar(pid: p.pid, name: "TERM_PROGRAM")
            results.append(DiscoveredSession(
                claudeSessionID: pick.sessionId,
                itermSessionID: iterm,
                terminalProgram: termProgram,
                cwd: cwd,
                branch: pick.branch,
                transcriptPath: pick.path,
                lastMessage: pick.lastMessage,
                pid: p.pid
            ))
        }
        return results
    }

    // MARK: - process enumeration

    private struct ProcInfo { let pid: Int; let tty: String }

    private static func listClaudeProcesses() -> [ProcInfo] {
        let (out, _) = run(["ps", "-ax", "-o", "pid=,ppid=,tty=,user=,comm="])
        let me = NSUserName()
        let ourPid = ProcessInfo.processInfo.processIdentifier
        var procs: [ProcInfo] = []
        for raw in out.split(separator: "\n") {
            // Columns: pid, ppid, tty, user, comm  (space-padded)
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 5,
                  let pid = Int(parts[0]),
                  let ppid = Int(parts[1]),
                  String(parts[3]) == me else { continue }
            // Skip processes spawned by ourselves (recap subprocess).
            if ppid == Int(ourPid) { continue }
            // comm 은 보통 "claude" (절대경로 없이 basename). 안전을 위해 basename 비교.
            let comm = (parts.dropFirst(4).joined(separator: " ") as NSString)
            let basename = (comm.lastPathComponent as String)
            guard basename == "claude" else { continue }
            procs.append(ProcInfo(pid: pid, tty: String(parts[2])))
        }
        return procs
    }

    // MARK: - per-process probes

    private static func lsofCwd(pid: Int) -> String? {
        // -Fn: machine-readable, 'n' field only (path)
        let (out, _) = run(["lsof", "-p", String(pid), "-a", "-d", "cwd", "-Fn"])
        for line in out.split(separator: "\n") {
            if line.hasPrefix("n") { return String(line.dropFirst()) }
        }
        return nil
    }

    /// 해당 PID 가 현재 열고 있는 transcript jsonl 의 경로. process ↔ session 매핑의
    /// 가장 신뢰성 있는 단서입니다 (같은 cwd 에 여러 세션이 있어도 정확히 1:1).
    private static func openTranscriptFor(pid: Int) -> String? {
        let (out, _) = run(["lsof", "-p", String(pid), "-Fn"])
        let projectsPath = NSHomeDirectory() + "/.claude/projects/"
        for line in out.split(separator: "\n") {
            guard line.hasPrefix("n") else { continue }
            let path = String(line.dropFirst())
            if path.hasPrefix(projectsPath) && path.hasSuffix(".jsonl") {
                return path
            }
        }
        return nil
    }

    private static func envVar(pid: Int, name: String) -> String? {
        // ps -E concatenates the env onto the command column.
        let (out, _) = run(["ps", "-E", "-p", String(pid), "-o", "command="])
        let prefix = "\(name)="
        for token in out.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            if token.hasPrefix(prefix) {
                return String(token.dropFirst(prefix.count))
            }
        }
        return nil
    }

    // MARK: - transcript scanning

    private struct TranscriptInfo {
        let path: String
        let cwd: String?
        let sessionId: String
        let branch: String?
        let lastMessage: String?
        let mtime: Date
    }

    private static func scanTranscripts() -> [TranscriptInfo] {
        let fm = FileManager.default
        let projectsDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").appendingPathComponent("projects")
        guard let subdirs = try? fm.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // 24시간 이상 갱신 없는 transcript 는 후보에서 제외 (idle 세션 cap).
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        var results: [TranscriptInfo] = []
        for sub in subdirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: sub,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                if mtime < cutoff { continue }
                if let info = parseTranscript(url: f, mtime: mtime) {
                    results.append(info)
                }
            }
        }
        return results
    }

    private static func parseTranscript(url: URL, mtime: Date) -> TranscriptInfo? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let sessionId = url.deletingPathExtension().lastPathComponent
        var cwd: String?
        var branch: String?
        var lastUser: String?
        var lastAssistant: String?
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            if branch == nil, let b = obj["gitBranch"] as? String, !b.isEmpty { branch = b }
            let type = obj["type"] as? String ?? ""
            if type == "user", let m = obj["message"] as? [String: Any],
               let t = extractText(m["content"]) { lastUser = t }
            else if type == "assistant", let m = obj["message"] as? [String: Any],
                    let t = extractText(m["content"]) { lastAssistant = t }
        }
        return TranscriptInfo(
            path: url.path,
            cwd: cwd,
            sessionId: sessionId,
            branch: branch,
            lastMessage: lastAssistant ?? lastUser,
            mtime: mtime
        )
    }

    private static func extractText(_ content: Any?) -> String? {
        if let s = content as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s }
        if let arr = content as? [[String: Any]] {
            for block in arr {
                if (block["type"] as? String) == "text",
                   let t = block["text"] as? String,
                   !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return t
                }
            }
        }
        return nil
    }

    // MARK: - subprocess runner

    /// Run a child process and return its stdout. stderr is discarded.
    ///
    /// IMPORTANT: We drain stdout via `readabilityHandler` because `Pipe`'s
    /// internal buffer is ~64 KB on macOS. `ps -ax` output exceeds that
    /// (~71 KB on this machine), so reading only after `waitUntilExit()` causes
    /// the child to block on write while we block on wait — classic deadlock.
    private static func run(_ args: [String]) -> (String, Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice

        let lock = NSLock()
        var collected = Data()
        let group = DispatchGroup()
        group.enter()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                lock.lock(); collected.append(chunk); lock.unlock()
            }
        }

        do { try p.run() } catch {
            NSLog("[discovery] failed to run %@: %@",
                  args.joined(separator: " "), String(describing: error))
            outPipe.fileHandleForReading.readabilityHandler = nil
            return ("", -1)
        }
        p.waitUntilExit()
        group.wait()
        return (String(data: collected, encoding: .utf8) ?? "", p.terminationStatus)
    }
}
