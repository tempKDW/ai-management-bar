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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Claude Code")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(store.sessions.count) active")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if store.sessions.isEmpty {
                VStack(spacing: 6) {
                    Text("활성 세션 없음")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("iTerm2 탭에서 Claude Code 를 띄우면\n여기에 자동으로 나타납니다.")
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

            HStack(spacing: 16) {
                Button("Refresh") { store.forceRecapAll() }
                    .buttonStyle(.plain)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
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
}

