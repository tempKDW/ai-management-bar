import Foundation
import UserNotifications
import AppKit

// NotifierHelper — UNUserNotificationCenter banner 를 띄우기 위한 별도 .app bundle.
// 메인 앱 (LSUIElement + 미서명) 에서 직접 UN 호출하면 권한 prompt 가 silently
// dropped 되거나, AppleScript `display notification` 도 NotificationCenter 가
// banner 를 drop 하는 케이스가 있다. helper 를 자체 bundleID 의 ad-hoc 서명
// .app 으로 분리해 macOS 가 별개 앱으로 인식하게 한다.
//
// 두 가지 모드:
//   send    — argv 에 `--title` 있으면 banner 발화 후 즉시 exit
//   receive — argv 비어있으면 (= banner click 으로 LaunchServices 가 launch)
//             NSApp + UN delegate 띄워 didReceive 콜백 대기. userInfo 의
//             iterm_session_id 로 iTerm 탭 활성화 후 exit.

struct Args {
    var title: String?
    var message: String?
    var sound: String?
    var itermSession: String?
}

func parseArgs() -> Args {
    var a = Args()
    var i = 1
    let argv = CommandLine.arguments
    while i < argv.count {
        let key = argv[i]
        switch key {
        case "--title":          i += 1; if i < argv.count { a.title = argv[i] }
        case "--message":        i += 1; if i < argv.count { a.message = argv[i] }
        case "--sound":          i += 1; if i < argv.count { a.sound = argv[i] }
        case "--iterm-session":  i += 1; if i < argv.count { a.itermSession = argv[i] }
        default: break
        }
        i += 1
    }
    return a
}

let args = parseArgs()

// MARK: - Send mode

func runSend(_ args: Args) -> Never {
    guard let title = args.title, let message = args.message else {
        FileHandle.standardError.write(Data("usage: NotifierHelper --title T --message M [--sound default] [--iterm-session ID]\n".utf8))
        exit(1)
    }

    final class SendDelegate: NSObject, UNUserNotificationCenterDelegate {
        // helper 가 LaunchServices 통해 launch 되면 잠깐 foreground active 가
        // 되는데 macOS 는 기본적으로 "자기 자신에게 보내는 알림" 을 suppress
        // 한다. willPresent 에서 .banner, .sound 를 명시 반환해 노출시킨다.
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .sound])
        }
        // send instance 가 add 후 sleep 중일 때 사용자가 banner 를 빠르게 click
        // 하면 macOS 가 살아있는 send process 에 dispatch 한다. didReceive 가
        // 없으면 click 이 silent no-op 이 되므로 receive 와 동일 동작 구현.
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            let userInfo = response.notification.request.content.userInfo
            if let sid = userInfo["iterm_session_id"] as? String, !sid.isEmpty {
                _ = activateITerm(sessionUniqueID: sid)
            }
            completionHandler()
        }
    }

    let center = UNUserNotificationCenter.current()
    let delegate = SendDelegate()
    center.delegate = delegate

    let done = DispatchSemaphore(value: 0)
    var ok = false

    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        guard granted else {
            done.signal()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        if let s = args.sound {
            content.sound = (s == "default") ? .default : UNNotificationSound(named: UNNotificationSoundName(s))
        }
        // banner click 시 receive 모드 helper 가 받아 iTerm 탭으로 점프.
        if let it = args.itermSession {
            content.userInfo = ["iterm_session_id": it]
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { addErr in
            ok = (addErr == nil)
            done.signal()
        }
    }

    _ = done.wait(timeout: .now() + 10)
    // add 후 system 이 willPresent delegate 호출 + banner 를 실제로 그릴 시간 확보.
    if ok {
        Thread.sleep(forTimeInterval: 1.5)
    }
    exit(ok ? 0 : 2)
}

// MARK: - Receive mode

/// banner click 으로 launch 됐을 때. NSApp 띄워 UN delegate 의 didReceive 콜백을
/// 기다리고, userInfo 의 iterm_session_id 로 iTerm 탭을 활성화한 뒤 exit.
final class ReceiveDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// LaunchServices delivery 누락 corner case 대비 안전망.
    static let timeout: TimeInterval = 10

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        // timeout 안 didReceive 안 오면 그냥 종료.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) {
            NSApp.terminate(nil)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let sid = userInfo["iterm_session_id"] as? String, !sid.isEmpty {
            _ = activateITerm(sessionUniqueID: sid)
        }
        completionHandler()
        // 처리 끝나면 즉시 exit (helper process 누수 방지).
        NSApp.terminate(nil)
    }
}

/// `ITermActivator.swift` 와 동일한 osascript 흐름. helper 는 별도 SPM target
/// 이라 직접 import 불가 — 30 줄 inline copy 가 빌드/maintenance 비용 면에서
/// share target 만드는 것보다 가볍다.
///
/// Return string 단계별 진단:
///   "selected:<name>"      — 매칭 + select 까지 성공 (가장 좋은 결과)
///   "matched-no-select"    — UUID 매칭은 됐는데 select 단계에서 something 이상
///   "not-found"            — UUID 매칭 실패 (세션 죽었거나 stale ID)
///   "" / err               — AppleScript 자체 실패 (권한, syntax)
func activateITerm(sessionUniqueID: String) -> (ok: Bool, returnString: String, error: String?) {
    let uuid: String = {
        if let colon = sessionUniqueID.lastIndex(of: ":") {
            return String(sessionUniqueID[sessionUniqueID.index(after: colon)...])
        }
        return sessionUniqueID
    }()
    let escaped = uuid.replacingOccurrences(of: "\\", with: "\\\\")
                      .replacingOccurrences(of: "\"", with: "\\\"")
    let script = """
    tell application "iTerm2"
        activate
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    if unique id of s is "\(escaped)" then
                        try
                            select w
                            tell w to select t
                            tell t to select s
                            return "selected:" & (name of s)
                        on error errMsg
                            return "matched-no-select:" & errMsg
                        end try
                    end if
                end repeat
            end repeat
        end repeat
        return "not-found"
    end tell
    """
    var errInfo: NSDictionary?
    guard let apple = NSAppleScript(source: script) else {
        return (false, "", "compile-failed")
    }
    let result = apple.executeAndReturnError(&errInfo)
    if let info = errInfo {
        return (false, result.stringValue ?? "", "AppleScript error: \(info)")
    }
    let str = result.stringValue ?? ""
    return (str.hasPrefix("selected:"), str, nil)
}

// MARK: - entry

if args.title != nil {
    runSend(args)
} else {
    let app = NSApplication.shared
    let delegate = ReceiveDelegate()
    app.delegate = delegate
    app.run()
}
