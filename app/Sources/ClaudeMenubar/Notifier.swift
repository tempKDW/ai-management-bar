import Foundation
import AppKit

/// 메뉴바 앱 (`LSUIElement=true`, 미서명) 에서는 `UNUserNotificationCenter` 권한
/// prompt 가 silently dropped 되는 macOS 이슈가 있다. 우회를 위해
/// `osascript "display notification"` 으로 시스템 알림을 띄운다 — Apple Events
/// 권한은 이미 받아둔 상태(iTerm2 자동화) 라 추가 권한 prompt 없음.
///
/// trade-off: click action (알림 누르면 iTerm 점프) 은 osascript 알림에서 지원
/// 안 됨. 사용자는 알림을 보고 메뉴바를 직접 열어 🔔 행을 클릭해 iTerm 으로
/// 이동한다.
enum Notifier {
    private static let lock = NSLock()
    private static var lastSent: [String: Date] = [:]
    /// 같은 세션에서 짧은 시간 안 반복되는 waiting 전이는 한 번만 알림.
    private static let throttle: TimeInterval = 5

    /// 호환성 entry point — UN* 시절에는 권한 prompt 가 있었지만 osascript 경로는
    /// setup 없이 동작한다. App init 에서 부르되 실제 동작은 없음.
    static func setup() {
        // intentionally empty — `display notification` requires no setup.
    }

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
            : "Action required"

        let script = """
        display notification "\(escape(body))" with title "\(escape(title))" sound name "default"
        """

        // In-process NSAppleScript can be silently dropped by macOS for
        // LSUIElement + unsigned bundles. Spawning /usr/bin/osascript as a
        // subprocess routes the notification through the binary's own
        // identity (script-runner) which posts reliably.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            NSLog("[notify] spawn failed: %@", String(describing: error))
            return
        }
        // Detached — banner is fire-and-forget; we don't block here.
        NSLog("[notify] sent for %@", session.id)
    }

    /// AppleScript string literal 안에 들어가는 사용자 입력 escape.
    private static func escape(_ s: String) -> String {
        return s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
