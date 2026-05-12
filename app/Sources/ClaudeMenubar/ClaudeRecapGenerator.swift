import Foundation
import CryptoKit

/// AFK 감지 후 백그라운드에서 `claude` CLI 를 호출해 한국어 recap 을 생성합니다.
///
/// 트리거 정책 (plan Phase 3):
/// - transcript mtime 이 `now - 5분` 이전 (AFK 추정)
/// - 마지막 recap 이후 transcript 가 변화함 (hash 다름)
/// - 같은 세션이 이미 in-flight 가 아님
final class ClaudeRecapGenerator {
    static let shared = ClaudeRecapGenerator()
    private init() {}

    /// AFK 임계값: 5분.
    static let afkThreshold: TimeInterval = 5 * 60

    private let lock = NSLock()
    private var inFlight: Set<String> = []   // sessionID 들
    private var cachedClaudePath: String?

    /// 트리거 조건을 검사하고 만족 시 background generate.
    @MainActor
    func generateIfNeeded(for session: SessionState, store: SessionStore) {
        guard let transcriptPath = session.transcriptPath,
              FileManager.default.fileExists(atPath: transcriptPath) else {
            return
        }
        // AFK 5분 확인
        guard let mtime = mtime(of: transcriptPath),
              Date().timeIntervalSince(mtime) >= Self.afkThreshold else {
            return
        }
        // hash 비교 + in-flight 검사
        guard let hash = hashFile(path: transcriptPath) else { return }
        if session.claudeRecap?.transcriptHash == hash { return }

        let sid = session.id
        lock.lock()
        if inFlight.contains(sid) { lock.unlock(); return }
        inFlight.insert(sid)
        lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            await self?.runGenerate(
                sessionID: sid,
                transcriptPath: transcriptPath,
                hash: hash,
                cwd: session.cwd,
                cwdDisplay: session.cwdDisplay,
                branch: session.branch,
                lastEditPath: session.lastEdit?.path,
                store: store
            )
            self?.lock.lock()
            self?.inFlight.remove(sid)
            self?.lock.unlock()
        }
    }

    // MARK: - generate pipeline

    private func runGenerate(
        sessionID: String,
        transcriptPath: String,
        hash: String,
        cwd: String,
        cwdDisplay: String,
        branch: String?,
        lastEditPath: String?,
        store: SessionStore
    ) async {
        guard let claudePath = resolveClaudePath() else {
            NSLog("[recap] claude CLI not found on PATH or common locations")
            return
        }
        let transcript = renderTranscript(path: transcriptPath, maxMessages: 150)
        if transcript.isEmpty {
            NSLog("[recap] empty input — skip")
            return
        }
        // 모델이 transcript 의 마지막 메시지에 이어 답하는 것을 막기 위해 명시적
        // 요약 요청으로 wrapping. transcript 자체는 fenced block 안에 둡니다.
        let wrapped = """
        아래는 Claude Code 세션 transcript 입니다. system prompt 의 규칙에 따라\
         **이 대화를 한국어 2 문장 (60~100 자) 로 요약**만 하세요. transcript 의 \
        문장을 그대로 인용하지 말고, 대화 이어가기 식으로 응답하지 마세요.

        ----- transcript -----
        \(transcript)
        ----- end -----

        요약:
        """
        let system = makeSystemPrompt(cwdDisplay: cwdDisplay, branch: branch, lastEditPath: lastEditPath)
        guard let text = await runClaude(claudePath: claudePath, system: system, stdin: wrapped) else {
            return
        }
        let recap = ClaudeRecap(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            transcriptHash: hash,
            generatedAt: Self.isoNow()
        )
        await MainActor.run {
            store.saveClaudeRecap(sessionID: sessionID, recap: recap)
        }
        NSLog("[recap] saved for session %@ (%d chars)", sessionID, recap.text.count)
    }

    private func makeSystemPrompt(cwdDisplay: String, branch: String?, lastEditPath: String?) -> String {
        let branchLine = branch.map { "- git branch: \($0)" } ?? "- git branch: (없음)"
        let editLine = lastEditPath.map { "- 마지막 편집 파일: \($0)" } ?? ""
        return """
        당신은 Claude Code 세션 transcript 의 요약기 (summarizer) 입니다. 사용자가 \
        세션에 돌아왔을 때 한눈에 파악하도록 한국어로 **매우 짧게** 요약합니다.

        컨텍스트:
        - 작업 폴더: \(cwdDisplay)
        \(branchLine)
        \(editLine)

        절대 규칙 (위반 금지):
        1. 출력은 한국어 1~2 문장. 총 60~100 자. 절대 100 자 초과 금지.
        2. 대화 이어가기 식 응답 금지 ("…하겠습니다", "확인드립니다" 같은 발화체 금지).
        3. transcript 의 문장을 그대로 인용 금지. 요약 표현으로 재작성.
        4. 인사·질문·아이콘·번호·머리말·markdown bullet 금지.
        5. "사용자는", "Claude 는" 같은 명시적 화자 표기 생략.

        형식: 평서문 1~2 줄.
        - 첫 줄: 지금 무엇을 하고 있는지 (현재 단계 · 막힌 지점).
        - 두 번째 줄 (선택): 다음 단계 한 가지.
        """
    }

    // MARK: - transcript → text

    private func renderTranscript(path: String, maxMessages: Int) -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        var rendered: [String] = []
        for line in text.split(whereSeparator: { $0.isNewline }) {
            guard let d = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                continue
            }
            let type = (obj["type"] as? String) ?? ""
            if type == "user", let msg = obj["message"] as? [String: Any] {
                let body = renderUserContent(msg["content"])
                if !body.isEmpty { rendered.append("사용자: \(body)") }
            } else if type == "assistant", let msg = obj["message"] as? [String: Any] {
                let body = renderAssistantContent(msg["content"])
                if !body.isEmpty { rendered.append("Claude: \(body)") }
            }
        }
        let tail = rendered.suffix(maxMessages)
        return tail.joined(separator: "\n\n")
    }

    private func renderUserContent(_ raw: Any?) -> String {
        if let s = raw as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let arr = raw as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for b in arr {
            let t = b["type"] as? String ?? ""
            if t == "text", let s = b["text"] as? String { parts.append(s) }
            else if t == "tool_result" {
                let isErr = (b["is_error"] as? Bool) ?? false
                let preview: String
                if let s = b["content"] as? String {
                    preview = String(s.prefix(200))
                } else if let inner = b["content"] as? [[String: Any]],
                          let first = inner.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String {
                    preview = String(first.prefix(200))
                } else { preview = "" }
                parts.append("[tool_result\(isErr ? " ERROR" : ""): \(preview)]")
            }
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func renderAssistantContent(_ raw: Any?) -> String {
        guard let arr = raw as? [[String: Any]] else {
            return (raw as? String) ?? ""
        }
        var parts: [String] = []
        for b in arr {
            let t = b["type"] as? String ?? ""
            if t == "text", let s = b["text"] as? String { parts.append(s) }
            else if t == "tool_use" {
                let name = (b["name"] as? String) ?? "tool"
                let input = (b["input"] as? [String: Any]) ?? [:]
                let detail: String
                if name == "Bash", let cmd = input["command"] as? String {
                    detail = String(cmd.prefix(100))
                } else if let fp = input["file_path"] as? String {
                    detail = fp
                } else {
                    detail = ""
                }
                parts.append("[tool: \(name)\(detail.isEmpty ? "" : " · \(detail)")]")
            }
        }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - subprocess

    private func runClaude(claudePath: String, system: String, stdin: String) async -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        p.arguments = ["-p", "--output-format", "text", "--model", "haiku", "--system-prompt", system]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = FileHandle.nullDevice

        // drain stdout asynchronously to avoid pipe buffer deadlock.
        var collected = Data()
        let lock = NSLock()
        let group = DispatchGroup()
        group.enter()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                lock.lock(); collected.append(chunk); lock.unlock()
            }
        }

        do {
            try p.run()
        } catch {
            NSLog("[recap] failed to launch claude: %@", String(describing: error))
            return nil
        }

        // write stdin then close
        let inData = (stdin + "\n").data(using: .utf8) ?? Data()
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: inData)
        } catch {
            NSLog("[recap] stdin write failed: %@", String(describing: error))
        }
        try? stdinPipe.fileHandleForWriting.close()

        p.waitUntilExit()
        group.wait()

        guard p.terminationStatus == 0 else {
            NSLog("[recap] claude exit %d", p.terminationStatus)
            return nil
        }
        return String(data: collected, encoding: .utf8)
    }

    // MARK: - claude binary resolution

    private func resolveClaudePath() -> String? {
        if let cached = cachedClaudePath { return cached }
        // 1. Common install locations
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
        ]
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            cachedClaudePath = path
            return path
        }
        // 2. Fallback: ask user shell (interactive login to load PATH)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "command -v claude"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, fm.isExecutableFile(atPath: trimmed) {
            cachedClaudePath = trimmed
            return trimmed
        }
        return nil
    }

    // MARK: - helpers

    private func mtime(of path: String) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.modificationDate] as? Date
    }

    private func hashFile(path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let h = SHA256.hash(data: data)
        return h.compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}
