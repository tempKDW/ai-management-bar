import Foundation
import UserNotifications

/// macOS 시스템 알림(banner + sound) 으로 waiting 전이를 사용자에게 알린다.
/// 사용 흐름:
///   1. 앱 시작 시 `Notifier.shared.setup()` 한 번
///   2. `SessionStore.reload()` 가 새로 waiting 으로 들어간 세션을 감지하면
///      `Notifier.shared.send(for: session)` 호출
///   3. 사용자가 알림 클릭 → delegate 가 iTerm 탭 활성화
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private override init() { super.init() }

    private let lock = NSLock()
    private var lastSent: [String: Date] = [:]
    /// 같은 세션에서 짧은 시간 안 반복되는 waiting 전이는 한 번만 알림.
    private let throttle: TimeInterval = 5

    /// 앱 시작 시 한 번. 권한 prompt 띄우고 delegate 등록.
    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                NSLog("[notify] auth error: %@", String(describing: error))
            } else {
                NSLog("[notify] auth granted: %@", granted ? "yes" : "no")
            }
        }
    }

    func send(for session: SessionState) {
        // throttle
        lock.lock()
        if let last = lastSent[session.id], Date().timeIntervalSince(last) < throttle {
            lock.unlock()
            return
        }
        lastSent[session.id] = Date()
        lock.unlock()

        let content = UNMutableNotificationContent()
        let cwd = session.cwdDisplay.isEmpty ? "Claude Code" : session.cwdDisplay
        content.title = "🔔 \(cwd)"
        content.body = session.currentTask?.isEmpty == false
            ? session.currentTask!
            : "Action required"
        content.sound = .default
        var info: [String: Any] = ["session_id": session.id]
        if let iterm = session.itermSessionID {
            info["iterm_session_id"] = iterm
        }
        content.userInfo = info

        let request = UNNotificationRequest(
            identifier: "waiting-\(session.id)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("[notify] send failed: %@", String(describing: error))
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 앱이 foreground 일 때도 배너 + 사운드를 보여준다 (메뉴바 앱이라 보통 background 지만 안전).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// 알림 클릭 → 해당 iTerm 세션으로 점프.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let iterm = info["iterm_session_id"] as? String {
            _ = ITermActivator.activate(sessionUniqueID: iterm)
        }
        completionHandler()
    }
}
