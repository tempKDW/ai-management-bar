import Foundation
import UserNotifications
import AppKit

// NotifierHelper — UNUserNotificationCenter banner 를 띄우기 위한 별도 .app bundle.
// 메인 앱 (LSUIElement + 미서명) 에서 직접 UN 호출하면 권한 prompt 가 silently
// dropped 되거나, AppleScript `display notification` 도 NotificationCenter 가
// banner 를 그리지 않는 케이스가 있다. helper 를 자체 bundleID 의 ad-hoc 서명
// .app 으로 분리해 macOS 가 별개 앱으로 인식하게 한다.
//
// Usage:
//   NotifierHelper --title "..." --message "..." [--sound default]
//
// Exit codes:
//   0 — banner 전송 성공 (시스템 큐에 add)
//   1 — argv 파싱 실패
//   2 — UN 권한 거부 / 시스템 거부

final class Delegate: NSObject, UNUserNotificationCenterDelegate {
    // helper 가 LaunchServices 통해 launch 되면 잠깐 foreground active 가 되는데,
    // macOS 는 기본적으로 "자기 자신에게 보내는 알림" 을 suppress 한다. willPresent
    // 에서 .banner, .sound 를 명시적으로 반환해 노출시킨다.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

func parseArgs() -> (title: String, message: String, sound: String?)? {
    var title: String?
    var message: String?
    var sound: String?
    var i = 1
    let argv = CommandLine.arguments
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--title":
            i += 1
            if i < argv.count { title = argv[i] }
        case "--message":
            i += 1
            if i < argv.count { message = argv[i] }
        case "--sound":
            i += 1
            if i < argv.count { sound = argv[i] }
        default:
            break
        }
        i += 1
    }
    guard let t = title, let m = message else { return nil }
    return (t, m, sound)
}

guard let args = parseArgs() else {
    FileHandle.standardError.write(Data("usage: NotifierHelper --title T --message M [--sound default]\n".utf8))
    exit(1)
}

let center = UNUserNotificationCenter.current()
let delegate = Delegate()
center.delegate = delegate

let done = DispatchSemaphore(value: 0)
var ok = false

center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
    guard granted else {
        done.signal()
        return
    }
    let content = UNMutableNotificationContent()
    content.title = args.title
    content.body = args.message
    if let s = args.sound {
        content.sound = (s == "default") ? .default : UNNotificationSound(named: UNNotificationSoundName(s))
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

// 첫 실행 시 사용자 권한 응답까지 대기.
_ = done.wait(timeout: .now() + 10)
// add 후 system 이 willPresent delegate 호출 + banner 를 실제로 그릴 시간 확보.
// 너무 빨리 exit 하면 delegate callback 이 호출 안 돼 banner 가 안 뜬다.
if ok {
    Thread.sleep(forTimeInterval: 1.5)
}
exit(ok ? 0 : 2)
