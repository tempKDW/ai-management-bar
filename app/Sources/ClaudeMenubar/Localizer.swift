import Foundation
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case auto
    case ko
    case en

    var id: String { rawValue }

    var pickerLabel: String {
        switch self {
        case .auto: return "Auto"
        case .ko:   return "KO"
        case .en:   return "EN"
        }
    }
}

/// 동적 KO/EN 토글. `.lproj` / `Localizable.strings` 인프라 대신 inline switch
/// dictionary 를 채택 — (1) SPM target 에서 strings 리소스 wiring 이 번거롭고,
/// (2) `Bundle.main` 동적 swap 으로 runtime 전환을 구현하기 까다로워서다. 키
/// 수가 25 개 안팎이라 dictionary 가 직관적이다.
@MainActor
final class Localizer: ObservableObject {
    static let shared = Localizer()

    private static let storageKey = "preferredLanguage"

    /// settings 패널의 Save 가 `setPreference(_:)` 로 일관 갱신한다. View 가
    /// 직접 `$preference` 에 binding 하지 않게 해서 영속화 누락을 막는다 —
    /// `@Published` 와 `didSet` 의 silent skip 케이스를 회피하기 위함.
    @Published private(set) var preference: AppLanguage

    /// 사용자 선택 영속화 + objectWillChange 발화. settings 패널 Save 에서만 호출.
    func setPreference(_ new: AppLanguage) {
        preference = new
        UserDefaults.standard.set(new.rawValue, forKey: Self.storageKey)
    }

    /// `auto` 면 시스템 locale 로 resolve. 명시적 ko/en 이면 그대로.
    var current: AppLanguage {
        switch preference {
        case .auto:
            let code = Locale.current.language.languageCode?.identifier ?? "en"
            return code == "ko" ? .ko : .en
        case .ko: return .ko
        case .en: return .en
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppLanguage.auto.rawValue
        self.preference = AppLanguage(rawValue: raw) ?? .auto
    }
}

enum L10nKey {
    case emptyTitle
    case emptySubtitle
    case activeCount(Int)
    case refresh
    case refreshing
    case quit
    case autoRecap
    case autoRecapWithTime(String)
    case autoRecapHint
    case compactRecapHeader
    case location
    case lastEditPrefix
    case copy
    case itermTab
    case justNow
    case minutesAgo(Int)
    case hoursAgo(Int)
    case daysAgo(Int)
    case showAll(Int)
    case collapse
    case actionRequired
    case discoveredFallback
    case settings
    case language
    case save
    case close
}

/// 메인 entrypoint. View 에서 `t(.emptyTitle)` 식으로 부른다.
func t(_ key: L10nKey, lang: AppLanguage? = nil) -> String {
    // Localizer.shared 접근은 MainActor isolated 라 호출부에서 보통 main 이지만,
    // off-main 호출 (recap generator 의 background) 도 가능하니 lang 인자로
    // override 받을 수 있게 한다. nil 이면 main 에서 동기 read.
    let resolved: AppLanguage
    if let lang = lang {
        resolved = lang
    } else if Thread.isMainThread {
        resolved = MainActor.assumeIsolated { Localizer.shared.current }
    } else {
        // Background thread fallback — UserDefaults 직접 읽어 resolve.
        let raw = UserDefaults.standard.string(forKey: "preferredLanguage") ?? "auto"
        let pref = AppLanguage(rawValue: raw) ?? .auto
        switch pref {
        case .auto:
            let code = Locale.current.language.languageCode?.identifier ?? "en"
            resolved = code == "ko" ? .ko : .en
        case .ko: resolved = .ko
        case .en: resolved = .en
        }
    }
    return resolved == .ko ? ko(key) : en(key)
}

private func ko(_ key: L10nKey) -> String {
    switch key {
    case .emptyTitle:                return "활성 세션 없음"
    case .emptySubtitle:             return "iTerm2 탭에서 Claude Code 를 띄우면\n여기에 자동으로 나타납니다."
    case .activeCount(let n):        return "\(n)개 활성"
    case .refresh:                   return "새로고침"
    case .refreshing:                return "새로고침 중…"
    case .quit:                      return "종료"
    case .autoRecap:                 return "자동 recap"
    case .autoRecapWithTime(let t):  return "자동 recap (\(t))"
    case .autoRecapHint:             return "AFK 5 분 후 자동 생성됩니다. 그 전엔 사용자가 진행 중이라고 봅니다."
    case .compactRecapHeader:        return "Compact recap (이전 컨텍스트 압축)"
    case .location:                  return "위치"
    case .lastEditPrefix:            return "(마지막 편집) "
    case .copy:                      return "복사"
    case .itermTab:                  return "iTerm 탭"
    case .justNow:                   return "방금"
    case .minutesAgo(let m):         return "\(m)분 전"
    case .hoursAgo(let h):           return "\(h)시간 전"
    case .daysAgo(let d):            return "\(d)일 전"
    case .showAll(let n):            return "전체 보기 (\(n) chars)"
    case .collapse:                  return "접기"
    case .actionRequired:            return "확인 필요"
    case .discoveredFallback:        return "활성 세션 (외부 발견)"
    case .settings:                  return "설정"
    case .language:                  return "언어"
    case .save:                      return "저장"
    case .close:                     return "닫기"
    }
}

private func en(_ key: L10nKey) -> String {
    switch key {
    case .emptyTitle:                return "No active sessions"
    case .emptySubtitle:             return "Start Claude Code in an iTerm2 tab\nand it'll show up here."
    case .activeCount(let n):        return "\(n) active"
    case .refresh:                   return "Refresh"
    case .refreshing:                return "Refreshing…"
    case .quit:                      return "Quit"
    case .autoRecap:                 return "Auto recap"
    case .autoRecapWithTime(let t):  return "Auto recap (\(t))"
    case .autoRecapHint:             return "Generated automatically after 5 min AFK; before that the user is still active."
    case .compactRecapHeader:        return "Compact recap (previous context summary)"
    case .location:                  return "Location"
    case .lastEditPrefix:            return "(last edit) "
    case .copy:                      return "Copy"
    case .itermTab:                  return "iTerm tab"
    case .justNow:                   return "just now"
    case .minutesAgo(let m):         return "\(m)m ago"
    case .hoursAgo(let h):           return "\(h)h ago"
    case .daysAgo(let d):            return "\(d)d ago"
    case .showAll(let n):            return "Show all (\(n) chars)"
    case .collapse:                  return "Collapse"
    case .actionRequired:            return "Action required"
    case .discoveredFallback:        return "Active session (discovered)"
    case .settings:                  return "Settings"
    case .language:                  return "Language"
    case .save:                      return "Save"
    case .close:                     return "Close"
    }
}
