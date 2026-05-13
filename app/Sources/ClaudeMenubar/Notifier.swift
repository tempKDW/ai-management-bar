import Foundation
import AppKit

/// 메뉴바 앱 (`LSUIElement=true`, 미서명) 에서 직접 UN 호출 / AppleScript
/// `display notification` 으로는 banner 가 안정적으로 노출되지 않는다 (권한
/// prompt silently dropped, deprecated NSUserNotification 으로의 fallback 도
/// macOS 26 에서는 no-op).
///
/// 해결: 자체 bundleID 를 가진 NotifierHelper.app 을 ad-hoc 서명해 동봉하고,
/// `NSWorkspace.openApplication` 으로 launch 한다. LaunchServices 경유라야
/// helper 의 신원으로 process 가 떠 UN 권한 + Notification Center 등록이 정상
/// 동작한다 (`Process` 로 binary 직접 호출하면 책임 앱이 ClaudeMenubar 로
/// 잡혀 helper 등록이 누락된다).
enum Notifier {
    private static let lock = NSLock()
    private static var lastSent: [String: Date] = [:]
    /// 같은 세션에서 짧은 시간 안 반복되는 waiting 전이는 한 번만 알림.
    private static let throttle: TimeInterval = 5

    /// 호환성 entry point — helper 경로는 setup 없이 동작한다.
    static func setup() {}

    static func send(for session: SessionState) {
        // throttle
        lock.lock()
        if let last = lastSent[session.id], Date().timeIntervalSince(last) < throttle {
            lock.unlock()
            return
        }
        lastSent[session.id] = Date()
        lock.unlock()

        let cwd = session.cwdDisplay.isEmpty ? "Claude Code" : session.cwdDisplay
        let title = "🔔 \(cwd)"
        let body = session.currentTask?.isEmpty == false
            ? session.currentTask!
            : t(.actionRequired)

        guard let helperApp = helperAppURL() else {
            NSLog("[notify] NotifierHelper.app not found in bundle")
            return
        }

        var argv: [String] = [
            "--title", title,
            "--message", body,
            "--sound", "default",
        ]
        // banner click 시 helper 가 어느 터미널로 점프할지 결정하는 식별자.
        // iTerm 은 탭 단위 (unique id), VSCode 는 cwd 단위 (workspace window).
        // 미지원 터미널은 식별자 미전달 → click 시 silent no-op (graceful).
        switch TerminalKind.from(program: session.terminalProgram) {
        case .iterm:
            if let it = session.itermSessionID, !it.isEmpty {
                argv.append(contentsOf: ["--iterm-session", it])
            }
        case .vscode:
            argv.append(contentsOf: ["--vscode-cwd", session.cwd])
        case .unsupported:
            break
        }

        let config = NSWorkspace.OpenConfiguration()
        config.arguments = argv
        config.activates = false
        NSWorkspace.shared.openApplication(at: helperApp, configuration: config) { _, err in
            if let err = err {
                NSLog("[notify] helper launch failed: %@", String(describing: err))
            }
        }
    }

    /// Bundle.main/Contents/Helpers/NotifierHelper.app. `swift run` 처럼 .app
    /// 밖에서 실행될 때 (개발 모드) 는 dist/ClaudeMenubar.app 의 helper 를
    /// fallback 으로 사용 — helper 는 .app bundle 형태여야 LaunchServices 가
    /// 자체 bundleID 로 launch 한다.
    private static func helperAppURL() -> URL? {
        let mainURL = Bundle.main.bundleURL
        let inBundle = mainURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Helpers")
            .appendingPathComponent("NotifierHelper.app")
        if FileManager.default.fileExists(atPath: inBundle.path) {
            return inBundle
        }
        // dev fallback: dist/ 에 빌드된 helper.app
        let fm = FileManager.default
        if let cwd = ProcessInfo.processInfo.environment["PWD"] {
            let candidate = URL(fileURLWithPath: cwd)
                .appendingPathComponent("dist/ClaudeMenubar.app/Contents/Helpers/NotifierHelper.app")
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
