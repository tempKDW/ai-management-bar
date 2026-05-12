import Foundation

enum SessionStatus: String, Codable, Equatable {
    case running
    case waiting
    case done
    case unknown

    var icon: String {
        switch self {
        case .running: return "🟢"
        case .waiting: return "🟡"
        case .done:    return "✅"
        case .unknown: return "⚪️"
        }
    }

    var label: String { rawValue }
}

struct LastEdit: Codable, Equatable {
    let path: String

    var basename: String { (path as NSString).lastPathComponent }
}

struct RecentEvent: Codable, Equatable, Identifiable {
    let ts: String?
    let kind: String     // "tool" | "user" | "assistant" | "error"
    let text: String

    var id: String { (ts ?? "") + "|" + kind + "|" + text }

    var icon: String {
        switch kind {
        case "tool":      return "🔧"
        case "user":      return "💬"
        case "assistant": return "🤖"
        case "error":     return "⚠️"
        default:          return "•"
        }
    }
}

struct Signals: Codable, Equatable {
    let stopReason: String?
    let errorRate: Double?
    let repeatedTool: String?

    enum CodingKeys: String, CodingKey {
        case stopReason   = "stop_reason"
        case errorRate    = "error_rate"
        case repeatedTool = "repeated_tool"
    }
}

/// Claude Code 가 컨텍스트 한도에 도달했을 때 자동으로 생성하는 compact summary.
struct LastRecap: Codable, Equatable {
    let ts: String?
    let text: String
}

/// 메뉴바 앱이 AFK 감지 후 백그라운드에서 `claude` CLI 로 생성한 자동 recap.
struct ClaudeRecap: Codable, Equatable {
    let text: String
    let transcriptHash: String
    let generatedAt: String

    enum CodingKeys: String, CodingKey {
        case text
        case transcriptHash = "transcript_hash"
        case generatedAt    = "generated_at"
    }
}

struct SessionState: Codable, Identifiable, Equatable {
    let claudeSessionID: String
    let itermSessionID: String?
    let cwd: String
    let cwdDisplay: String
    let branch: String?
    let transcriptPath: String?
    let state: SessionStatus
    let currentTask: String?
    let lastPrompt: String?
    let updatedAt: String
    let pid: Int?

    // Phase 2: re-entry brief fields
    let lastViewedAt: String?
    let lastEdit: LastEdit?
    let recentEvents: [RecentEvent]?
    let signals: Signals?
    let nextStepNote: String?
    let lastRecap: LastRecap?
    let claudeRecap: ClaudeRecap?

    var id: String { claudeSessionID }

    enum CodingKeys: String, CodingKey {
        case claudeSessionID  = "claude_session_id"
        case itermSessionID   = "iterm_session_id"
        case cwd
        case cwdDisplay       = "cwd_display"
        case branch
        case transcriptPath   = "transcript_path"
        case state
        case currentTask      = "current_task"
        case lastPrompt       = "last_prompt"
        case updatedAt        = "updated_at"
        case pid
        case lastViewedAt     = "last_viewed_at"
        case lastEdit         = "last_edit"
        case recentEvents     = "recent_events"
        case signals
        case nextStepNote     = "next_step_note"
        case lastRecap        = "last_recap"
        case claudeRecap      = "claude_recap"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.claudeSessionID = try c.decode(String.self, forKey: .claudeSessionID)
        self.itermSessionID  = try? c.decodeIfPresent(String.self, forKey: .itermSessionID)
        self.cwd             = (try? c.decode(String.self, forKey: .cwd)) ?? ""
        self.cwdDisplay      = (try? c.decode(String.self, forKey: .cwdDisplay)) ?? ""
        self.branch          = try? c.decodeIfPresent(String.self, forKey: .branch)
        self.transcriptPath  = try? c.decodeIfPresent(String.self, forKey: .transcriptPath)
        let raw = (try? c.decode(String.self, forKey: .state)) ?? ""
        self.state           = SessionStatus(rawValue: raw) ?? .unknown
        self.currentTask     = try? c.decodeIfPresent(String.self, forKey: .currentTask)
        self.lastPrompt      = try? c.decodeIfPresent(String.self, forKey: .lastPrompt)
        self.updatedAt       = (try? c.decode(String.self, forKey: .updatedAt)) ?? ""
        self.pid             = try? c.decodeIfPresent(Int.self, forKey: .pid)
        self.lastViewedAt    = try? c.decodeIfPresent(String.self, forKey: .lastViewedAt)
        self.lastEdit        = try? c.decodeIfPresent(LastEdit.self, forKey: .lastEdit)
        self.recentEvents    = try? c.decodeIfPresent([RecentEvent].self, forKey: .recentEvents)
        self.signals         = try? c.decodeIfPresent(Signals.self, forKey: .signals)
        self.nextStepNote    = try? c.decodeIfPresent(String.self, forKey: .nextStepNote)
        self.lastRecap       = try? c.decodeIfPresent(LastRecap.self, forKey: .lastRecap)
        self.claudeRecap     = try? c.decodeIfPresent(ClaudeRecap.self, forKey: .claudeRecap)
    }

    /// Truncate a long path to a compact form: ~/.../leaf
    var compactPath: String {
        let parts = cwdDisplay.split(separator: "/").map(String.init)
        if parts.count <= 3 { return cwdDisplay }
        return "~/.../" + parts.suffix(1).joined(separator: "/")
    }

    /// Whether there's been transcript activity since last_viewed_at.
    var hasUnreadSinceLastViewed: Bool {
        guard let lastViewed = lastViewedAt, !lastViewed.isEmpty else {
            // Never viewed → consider unread if currently active.
            return state == .running || state == .waiting
        }
        return updatedAt > lastViewed
    }
}
