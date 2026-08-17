import SwiftUI

/// 历史会话列表:「本地会话」/「桥上发现」两段,支持搜索、切换、新建、
/// 重命名、删除(远端同步,经 ChatStore.deleteSession)。
struct SessionListView: View {
    let sessions: [SessionMeta]
    let currentChatID: String?
    let onSelect: (SessionMeta) -> Void
    let onNew: () -> Void
    let onDelete: (SessionMeta) -> Void
    let onRename: (SessionMeta, String) -> Void

    @State private var searchText = ""
    @State private var renameTarget: SessionMeta?
    @State private var renameTitle = ""
    @State private var showingRenameAlert = false

    private var filtered: [SessionMeta] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            ($0.preview ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }
    private var local: [SessionMeta] { filtered.filter { !$0.isRemoteOnly } }
    private var remote: [SessionMeta] { filtered.filter { $0.isRemoteOnly } }

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
                        Section("本地会话") {
                            ForEach(local) { row($0) }
                        }
                        if !remote.isEmpty {
                            Section("桥上发现") {
                                ForEach(remote) { row($0) }
                            }
                        }
                    }
                    .searchable(text: $searchText, prompt: "搜索会话")
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
            .alert("重命名会话", isPresented: $showingRenameAlert) {
                TextField("标题", text: $renameTitle)
                Button("保存") {
                    if let target = renameTarget {
                        onRename(target, renameTitle)
                    }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private func row(_ meta: SessionMeta) -> some View {
        Button {
            onSelect(meta)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(meta.title)
                        .font(.headline)
                        .lineLimit(1)
                    if meta.isRemoteOnly {
                        Text("远端")
                            .font(.caption2)
                            .bold()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
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
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                onDelete(meta)
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                renameTarget = meta
                renameTitle = meta.title
                showingRenameAlert = true
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            .tint(.orange)
        }
    }
}