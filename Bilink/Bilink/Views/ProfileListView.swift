import SwiftUI

/// 编辑弹窗目标:新增 or 编辑指定机器。用 Identifiable 驱动 .sheet(item:),确保每次呈现都拿到最新 profile。
private enum ProfileEditorTarget: Identifiable {
    case add
    case edit(ConnectionProfile)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let profile): return profile.id.uuidString
        }
    }
}

/// 机器列表主页:多连接 profile 的增删改与连接入口;连接失败留在本页提示。
struct ProfileListView: View {
    @Bindable var store: ConnectionStore
    let profileStore: ProfileStore
    let sessionStore: SessionStore
    @State private var editorTarget: ProfileEditorTarget?
    @State private var deletingProfile: ConnectionProfile?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if profileStore.profiles.isEmpty {
                    ContentUnavailableView(
                        "还没有远程机器",
                        systemImage: "desktopcomputer",
                        description: Text("添加一台运行桥与 grok 的机器,即可远程连接")
                    )
                } else {
                    List {
                        ForEach(profileStore.profiles) { profile in
                            row(profile)
                        }
                    }
                    .confirmationDialog(
                        "删除该机器?",
                        isPresented: Binding(
                            get: { deletingProfile != nil },
                            set: { if !$0 { deletingProfile = nil } }
                        ),
                        titleVisibility: .visible
                    ) {
                        Button("删除(同时清除 token 与本地会话)", role: .destructive) {
                            if let profile = deletingProfile {
                                delete(profile)
                            }
                        }
                        Button("取消", role: .cancel) { deletingProfile = nil }
                    } message: {
                        Text("将删除此机器的连接配置与该机器全部本地会话记录。")
                    }
                }
            }
            .navigationTitle("远程机器")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editorTarget = .add
                    } label: {
                        Label("添加机器", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editorTarget) { target in
                switch target {
                case .add:
                    ProfileEditView(profileStore: profileStore, profile: nil)
                case .edit(let profile):
                    ProfileEditView(profileStore: profileStore, profile: profile)
                }
            }
            .overlay(alignment: .top) {
                if let message = errorMessage {
                    banner(message) { errorMessage = nil }
                }
                if case .failed(let acpError) = store.state {
                    banner(acpError.errorDescription ?? "连接失败") {
                        store.state = .idle
                    }
                }
            }
        }
    }

    private func row(_ profile: ConnectionProfile) -> some View {
        Button {
            connect(profile)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(profile.name)
                        .font(.headline)
                        .lineLimit(1)
                    if store.state == .connecting, store.config?.profileID == profile.id {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Text(profile.url)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(sessionStore.sessions(for: profile.id).count) 个会话"
                     + (profile.lastUsedAt.map { " · 最后使用 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        // 左滑:编辑 + 删除(与用户预期一致);长按菜单同样提供
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deletingProfile = profile
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                editorTarget = .edit(profile)
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                editorTarget = .edit(profile)
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deletingProfile = profile
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func connect(_ profile: ConnectionProfile) {
        errorMessage = nil
        guard let token = profileStore.token(for: profile.id) else {
            errorMessage = "该机器未保存 token,请编辑后重试"
            return
        }
        let config = ConnectionConfig(name: profile.name, url: profile.url, token: token,
                                      profileID: profile.id,
                                      encryptionKey: profileStore.encryptKey(for: profile.id))
        Task {
            await store.connect(config)
            // 在途期间 profile 可能被删除:仅当仍存在且连接成功时才刷新 lastUsedAt
            if store.state == .connected,
               profileStore.profiles.contains(where: { $0.id == profile.id }) {
                profileStore.touch(profile)
            }
        }
    }

    /// 删除机器:级联清除 Keychain token 与该机器全部本地会话;若正在连接则断开。
    private func delete(_ profile: ConnectionProfile) {
        profileStore.delete(id: profile.id)
        sessionStore.removeProfile(profileID: profile.id)
        if store.config?.profileID == profile.id {
            store.disconnect()
        }
    }

    private func banner(_ message: String, onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
        }
        .font(.footnote)
        .foregroundStyle(.red)
        .padding(8)
        .background(.bar, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .transition(.opacity)
    }
}
