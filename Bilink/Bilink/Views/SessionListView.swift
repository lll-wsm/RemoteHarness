import SwiftUI

/// 历史会话列表:按最近更新倒序,支持切换、新建、滑动删除。
struct SessionListView: View {
    let sessions: [SessionMeta]
    let currentChatID: String?
    let onSelect: (SessionMeta) -> Void
    let onNew: () -> Void
    let onDelete: (SessionMeta) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "暂无历史会话",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("每次对话都会自动保存,可随时回来继续")
                    )
                } else {
                    List {
                        ForEach(sessions) { meta in
                            Button {
                                onSelect(meta)
                            } label: {
                                row(meta)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                onDelete(sessions[index])
                            }
                        }
                    }
                }
            }
            .navigationTitle("历史会话")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onNew) {
                        Label("新建会话", systemImage: "plus")
                    }
                }
            }
        }
    }

    private func row(_ meta: SessionMeta) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(meta.title)
                    .font(.headline)
                    .lineLimit(1)
                if meta.chatID == currentChatID {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.tint)
                }
            }
            if let preview = meta.preview {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text("\(meta.messageCount) 条消息 · \(meta.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}