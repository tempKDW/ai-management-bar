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

    /// 외부 (SessionStore Refresh) 에서 완료 감지용으로 사용.
    func hasInFlight() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !inFlight.isEmpty
    }

    /// 트리거 조건을 검사하고 만족 시 background generate.
    /// `force == true` 면 AFK 5분·hash 일치 가드 모두 건너뜁니다 (Refresh 버튼 용).
    @MainActor
    func generateIfNeeded(for session: SessionState, store: SessionStore, force: Bool = false) {
        guard let transcriptPath = session.transcriptPath,
              FileManager.default.fileExists(atPath: transcriptPath) else {
            return
        }
        if !force {
            // AFK 5분 확인
            guard let mtime = mtime(of: transcriptPath),
                  Date().timeIntervalSince(mtime) >= Self.afkThreshold else {
                return
            }
        }
        // hash (force 여도 캐시 키로는 필요)
        guard let hash = hashFile(path: transcriptPath) else { return }
        if !force, session.claudeRecap?.transcriptHash == hash { return }

        let sid = session.id
        // MainActor 에서 사용자 선택 언어를 capture — detached task 에서는 위
        // ObservableObject 에 직접 접근 불가.
        let lang = Localizer.shared.current
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
                lang: lang,
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
        lang: AppLanguage,
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
        let wrapped = wrapTranscript(transcript, lang: lang)
        let system = makeSystemPrompt(
            cwdDisplay: cwdDisplay, branch: branch, lastEditPath: lastEditPath, lang: lang
        )
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

    private func wrapTranscript(_ transcript: String, lang: AppLanguage) -> String {
        switch lang {
        case .ko, .auto:
            return """
            **출력 언어: 한국어 전용.** transcript 가 영어·일본어·중국어 등 어떤 \
            언어이든 요약은 반드시 한국어로 작성하세요. transcript 의 언어를 따라 \
            가지 마세요.

            아래는 Claude Code 세션 transcript 입니다. system prompt 의 규칙에 따라\
             **이 대화를 한국어 2 문장 (60~100 자) 로 요약**만 하세요. transcript 의 \
            문장을 그대로 인용하지 말고, 대화 이어가기 식으로 응답하지 마세요.

            ----- transcript -----
            \(transcript)
            ----- end -----

            요약 (한국어):
            """
        case .en:
            return """
            **OUTPUT LANGUAGE: English ONLY.** Even if the transcript is in Korean, \
            Japanese, Chinese, or any other language, your summary MUST be written \
            in English. Do not echo the transcript's language.

            Below is a Claude Code session transcript. Following the rules in the \
            system prompt, **summarize the conversation in 1-2 English sentences \
            (80-130 chars)** only. Do not quote the transcript verbatim, and do \
            not continue the conversation.

            ----- transcript -----
            \(transcript)
            ----- end -----

            Summary (English):
            """
        }
    }

    private func makeSystemPrompt(
        cwdDisplay: String, branch: String?, lastEditPath: String?, lang: AppLanguage
    ) -> String {
        switch lang {
        case .ko, .auto:
            let branchLine = branch.map { "- git branch: \($0)" } ?? "- git branch: (없음)"
            let editLine = lastEditPath.map { "- 마지막 편집 파일: \($0)" } ?? ""
            return """
            **출력 언어: 한국어 전용.** transcript 가 어떤 언어로 쓰였든 결과는 \
            반드시 한국어. 이 규칙은 다른 모든 규칙보다 우선합니다.

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
        case .en:
            let branchLine = branch.map { "- git branch: \($0)" } ?? "- git branch: (none)"
            let editLine = lastEditPath.map { "- last edited file: \($0)" } ?? ""
            return """
            **OUTPUT LANGUAGE: English ONLY.** Regardless of the transcript's \
            language, your output MUST be in English. This rule overrides every \
            other rule below.

            You are a summarizer for a Claude Code session transcript. Produce a \
            **very short** English summary so the user can re-orient at a glance \
            when returning to the session.

            Context:
            - working dir: \(cwdDisplay)
            \(branchLine)
            \(editLine)

            Hard rules (do not violate):
            1. Output 1-2 English sentences. Total 80-130 chars. Never exceed 130 chars.
            2. Do not write conversational replies ("I will...", "Sure, let me..."). State facts only.
            3. Do not quote the transcript verbatim. Rephrase as a summary.
            4. No greetings, questions, emoji, numbering, headings, or markdown bullets.
            5. Drop explicit speaker labels like "the user" or "Claude" where possible.

            Format: 1-2 declarative lines.
            - Line 1: what is happening now (current step / where it is stuck).
            - Line 2 (optional): one obvious next step.
            """
        }
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

    /// Reference-type Data sink so the `readabilityHandler` (which Swift treats
    /// as `@Sendable`) can append without capturing a `var`.
    private final class DataSink: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ chunk: Data) {
            lock.lock(); buffer.append(chunk); lock.unlock()
        }
        func snapshot() -> Data {
            lock.lock(); defer { lock.unlock() }
            return buffer
        }
    }

    private func runClaude(claudePath: String, system: String, stdin: String) async -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        p.arguments = ["-p", "--output-format", "text", "--model", "haiku", "--system-prompt", system]
        // Force the spawned claude's cwd to /tmp so it never probes a TCC-
        // protected folder (Documents / Downloads / Desktop / iCloud Drive).
        // Otherwise the child inherits our app's cwd and triggers a
        // "ClaudeMenubar wants to access this folder" prompt the first time
        // its auto-discovery (CLAUDE.md, .git, package.json, ...) reaches one.
        let safeCwd = NSTemporaryDirectory()
        p.currentDirectoryURL = URL(fileURLWithPath: safeCwd)
        // hook.py 가 spawn 된 claude 의 lifecycle event 를 무시하도록 env 마커 주입.
        // 부모 환경을 inherit 하므로 PATH 등 시스템 변수도 함께 전달.
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_MENUBAR_INTERNAL"] = "1"
        env["PWD"] = safeCwd   // some tools read PWD instead of getcwd()
        p.environment = env
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = FileHandle.nullDevice

        // Drain stdout asynchronously to avoid pipe buffer deadlock.
        // Use a reference-type sink because the handler is a @Sendable closure
        // (capturing a var Data would violate Swift concurrency rules).
        let sink = DataSink()
        let group = DispatchGroup()
        group.enter()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                sink.append(chunk)
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
        return String(data: sink.snapshot(), encoding: .utf8)
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
