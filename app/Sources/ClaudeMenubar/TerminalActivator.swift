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
///   - vscode     → `open -b com.microsoft.VSCode <cwd>` (workspace window 단위.
///                  VSCode 가 stable terminal-instance id 를 외부에 노출하지
///                  않아 탭 단위 점프는 불가능)
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
            return openVSCode(cwd: session.cwd)
        case .unsupported:
            return "unsupported terminal: \(session.terminalProgram ?? "nil")"
        }
    }

    /// `open -b com.microsoft.VSCode <cwd>` 로 cwd 가 열린 VSCode workspace
    /// window 를 frontmost 로 가져온다 (이미 열려 있으면 activate, 없으면 새
    /// window). VSCode 미설치 환경에서는 open 이 non-zero exit → 에러 반환,
    /// caller 가 graceful 처리.
    static func openVSCode(cwd: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", "com.microsoft.VSCode", cwd]
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                return "open exit \(p.terminationStatus)"
            }
            return nil
        } catch {
            return "open spawn failed: \(error)"
        }
    }
}
