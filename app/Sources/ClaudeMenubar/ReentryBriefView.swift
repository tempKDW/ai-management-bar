import SwiftUI
import AppKit

/// 단순화된 re-entry brief panel: 자동 recap + Compact recap (있을 때) + 위치.
/// Phase 3 에서 timeline · signals · next_step 메모 · LLM 요약 버튼은 제거됐습니다.
struct ReentryBriefView: View {
    let session: SessionState
    let store: SessionStore

    @State private var recapExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            claudeRecapSection
            if let recap = session.lastRecap {
                compactRecapSection(recap)
            }
            locationSection
            actionRow
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var claudeRecapSection: some View {
        if let recap = session.claudeRecap {
            sectionContainer(icon: "🌀", title: "자동 recap (\(relativeTime(recap.generatedAt)))") {
                Text(recap.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        } else {
            sectionContainer(icon: "🌀", title: "자동 recap") {
                Text("AFK 5 분 후 자동 생성됩니다. 그 전엔 사용자가 진행 중이라고 봅니다.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func compactRecapSection(_ recap: LastRecap) -> some View {
        let full = recap.text
        let preview = String(full.prefix(280))
        let truncated = full.count > preview.count
        return sectionContainer(icon: "📋", title: "Compact recap (이전 컨텍스트 압축)") {
            VStack(alignment: .leading, spacing: 4) {
                Text(recapExpanded ? full : preview + (truncated ? "…" : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if truncated {
                    Button(recapExpanded ? "Collapse" : "Show all (\(full.count) chars)") {
                        recapExpanded.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var locationSection: some View {
        sectionContainer(icon: "📍", title: "위치") {
            VStack(alignment: .leading, spacing: 2) {
                if let edit = session.lastEdit {
                    Text(edit.basename)
                        .font(.system(size: 11, weight: .medium))
                    Text("(마지막 편집) \(edit.path)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 4) {
                    Text(session.cwdDisplay)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let b = session.branch, !b.isEmpty {
                        Text("· \(b)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                copyBriefToPasteboard()
            } label: {
                Label("복사", systemImage: "doc.on.doc")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)

            Button {
                activate()
            } label: {
                Label("iTerm 탭", systemImage: "arrow.up.right.square")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.top, 4)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionContainer<Content: View>(
        icon: String, title: String, @ViewBuilder _ body: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(icon).font(.system(size: 10))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            body().padding(.leading, 16)
        }
    }

    private func relativeTime(_ iso: String) -> String {
        guard let d = parseISO(iso) else { return "방금" }
        let dt = Date().timeIntervalSince(d)
        if dt < 60 { return "방금" }
        if dt < 3600 { return "\(Int(dt / 60))분 전" }
        if dt < 86400 { return "\(Int(dt / 3600))시간 전" }
        return "\(Int(dt / 86400))일 전"
    }

    private func parseISO(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }

    private func copyBriefToPasteboard() {
        var lines: [String] = []
        if let r = session.claudeRecap {
            lines.append("🌀 자동 recap (\(relativeTime(r.generatedAt)))")
            lines.append(r.text)
            lines.append("")
        }
        if let r = session.lastRecap {
            lines.append("📋 Compact recap")
            lines.append(r.text)
            lines.append("")
        }
        lines.append("📍 \(session.cwdDisplay) · \(session.branch ?? "")")
        if let edit = session.lastEdit {
            lines.append("   last edit: \(edit.path)")
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private func activate() {
        guard let uid = session.itermSessionID else {
            NSSound.beep()
            return
        }
        _ = ITermActivator.activate(sessionUniqueID: uid)
    }
}
