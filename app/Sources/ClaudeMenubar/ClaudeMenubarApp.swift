import SwiftUI
import AppKit

@main
struct ClaudeMenubarApp: App {
    @StateObject private var store = SessionStore()

    init() {
        // Idempotent: writes hook.py to ~/.claude/menubar/bin/ and patches
        // ~/.claude/settings.json. Backups the settings file before mutation.
        do {
            let msg = try HookInstaller.install()
            NSLog("[claude-menubar] hook install: %@", msg)
        } catch {
            NSLog("[claude-menubar] hook install failed: %@", String(describing: error))
        }
        // 권한 요청 발생 시 macOS Notification 으로 알리기 (osascript 우회).
        Notifier.setup()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            Label {
                Text(menuTitle)
            } icon: {
                Image(systemName: menuIcon)
                    .foregroundStyle(menuIconColor)
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var menuTitle: String {
        let n = store.sessions.count
        return n == 0 ? "" : "\(n)"
    }

    /// 상태 인식 아이콘 우선순위: waiting (action 필요) > running > idle/done/empty.
    /// idle 은 시급도가 낮아 메뉴바 아이콘을 강조하지 않습니다 (secondary).
    private var menuIcon: String {
        if store.sessions.contains(where: { $0.state == .waiting }) {
            return "exclamationmark.bubble.fill"
        }
        if store.sessions.contains(where: { $0.state == .running }) {
            return "bubble.left.and.bubble.right.fill"
        }
        return "bubble.left.and.bubble.right"
    }

    private var menuIconColor: Color {
        if store.sessions.contains(where: { $0.state == .waiting }) {
            return .orange
        }
        if store.sessions.contains(where: { $0.state == .running }) {
            return .primary
        }
        return .secondary   // idle · done · empty
    }
}

struct MenuContent: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var localizer = Localizer.shared

    @State private var showingSettings: Bool = false
    /// 패널이 열려 있는 동안의 임시 선택값. Save 시점에 Localizer 로 commit.
    /// Close 면 그대로 폐기되고 다음 패널 열기 때 현재 preference 로 재초기화.
    @State private var draftLanguage: AppLanguage = .auto

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Claude Code")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(t(.activeCount(store.sessions.count)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if store.sessions.isEmpty {
                VStack(spacing: 6) {
                    Text(t(.emptyTitle))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(t(.emptySubtitle))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.sessions) { s in
                            SessionRowView(session: s, store: store)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 576)
            }

            Divider()

            if showingSettings {
                settingsPanel
                Divider()
            }

            HStack(spacing: 12) {
                if store.isRefreshing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 14, height: 14)
                        Text(t(.refreshing))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button(t(.refresh)) { store.forceRecapAll() }
                        .buttonStyle(.plain)
                        .disabled(store.isRefreshing)
                }
                Spacer()
                Button {
                    // 패널 진입 시 현재 preference 를 draft 로 동기화.
                    if !showingSettings {
                        draftLanguage = localizer.preference
                    }
                    showingSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help(t(.settings))
                Button(t(.quit)) { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 400)
        .onAppear {
            store.markAllViewed()
        }
    }

    /// gear 클릭 시 footer 위에 등장하는 inline settings 패널.
    /// Save 누를 때만 (변경 시) recap 재생성이 일어나도록 해서 빠른 picker 토글이
    /// 중복 refresh 를 일으키지 않는다.
    private var settingsPanel: some View {
        HStack(spacing: 10) {
            Text(t(.language))
                .foregroundStyle(.secondary)
            Picker("", selection: $draftLanguage) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.pickerLabel).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)

            Spacer()

            Button(t(.close)) {
                showingSettings = false
            }
            .buttonStyle(.plain)

            Button(t(.save)) {
                let changed = draftLanguage != localizer.preference
                if changed {
                    localizer.setPreference(draftLanguage)
                    store.forceRecapAll()
                }
                showingSettings = false
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

