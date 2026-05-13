import Foundation

/// 어떤 터미널 emulator 가 세션을 띄웠는지의 enum 표현. SessionState 의
/// `terminalProgram` (= TERM_PROGRAM env) 으로부터 도출.
enum TerminalKind {
    case iterm
    case vscode
    case unsupported

    static func from(program: String?) -> TerminalKind {
        switch program {
        case "iTerm.app": return .iterm
        case "vscode":    return .vscode
        default:          return .unsupported
        }
    }

    /// UI 배지에 그대로 노출되는 brand name. nil 이면 배지 미표시.
    var displayName: String? {
        switch self {
        case .iterm:       return "iTerm"
        case .vscode:      return "VSCode"
        case .unsupported: return nil
        }
    }
}

/// Row click / banner click 의 점프 dispatcher.
///
/// 분기:
///   - iTerm.app  → `ITermActivator` (AppleScript unique id 매칭, 탭 단위)
///   - vscode     → 비활성 (no-op). VSCode 는 stable terminal-instance id 를
///                  외부에 노출하지 않고, `open -b com.microsoft.VSCode <cwd>`
///                  는 cwd 가 VSCode workspace 와 정확히 일치하지 않으면 새
///                  창을 띄워 사용자 작업 흐름을 망치므로 점프 자체를 뺀다.
///                  배지는 표시되어 어느 터미널에서 띄운 세션인지만 알린다.
///   - 그 외      → "unsupported" 반환, caller 가 beep 등으로 처리
enum TerminalActivator {
    @discardableResult
    static func activate(session: SessionState) -> String? {
        switch TerminalKind.from(program: session.terminalProgram) {
        case .iterm:
            guard let uid = session.itermSessionID, !uid.isEmpty else {
                return "iTerm session id missing"
            }
            return ITermActivator.activate(sessionUniqueID: uid)
        case .vscode:
            return "vscode jump disabled (no stable terminal id)"
        case .unsupported:
            // Legacy fallback: terminal_program 이 박히기 전 (옛 hook) 상태
            // 파일은 iterm_session_id 만 있을 수 있다. 그 경우엔 iTerm 으로
            // 점프 시도해 회귀 방지.
            if let uid = session.itermSessionID, !uid.isEmpty {
                return ITermActivator.activate(sessionUniqueID: uid)
            }
            return "unsupported terminal: \(session.terminalProgram ?? "nil")"
        }
    }
}
