import SwiftUI
import AppKit

struct SessionRowView: View {
    let session: SessionState
    let store: SessionStore

    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            mainRow
            if expanded {
                Divider()
                ReentryBriefView(session: session, store: store)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .background(hovering ? Color.gray.opacity(0.08) : Color.clear)
    }

    private var mainRow: some View {
        HStack(alignment: .top, spacing: 8) {
            // unread marker · status icon
            VStack(spacing: 2) {
                if session.hasUnreadSinceLastViewed {
                    Text("🔵").font(.system(size: 8))
                } else {
                    Text(" ").font(.system(size: 8))
                }
                Text(session.state.icon).font(.system(size: 13))
            }
            .frame(width: 18)

            Button {
                activate()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.cwdDisplay.isEmpty ? "(unknown)" : session.cwdDisplay)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let b = session.branch, !b.isEmpty {
                            Text("·").foregroundStyle(.secondary)
                            Text(b)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let badge = TerminalKind.from(program: session.terminalProgram).displayName {
                            Text("·").foregroundStyle(.secondary)
                            Text(badge)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(session.state.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(stateColor)
                    }
                    if let task = session.currentTask, !task.isEmpty {
                        Text(task)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // chevron — separate hit area
            Button {
                expanded.toggle()
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onHover { hovering = $0 }
    }

    private var stateColor: Color {
        switch session.state {
        case .running: return .green
        case .waiting: return .orange
        case .idle:    return .blue
        case .done:    return .gray
        case .unknown: return .secondary
        }
    }

    private func activate() {
        if let err = TerminalActivator.activate(session: session) {
            NSLog("[claude-menubar] activate failed: %@", err)
            NSSound.beep()
        }
    }
}
