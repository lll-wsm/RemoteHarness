import SwiftUI

/// 聊天页:消息列表(流式)+ 输入栏 + 状态条;历史会话列表(切换/新建/删除/重命名/远端发现)。
struct ChatView: View {
    @Bindable var store: ConnectionStore
    let config: ConnectionConfig
    let sessionStore: SessionStore
    @State private var chatStore: ChatStore?
    @State private var showSessions = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerBar
                Divider()
                Group {
                    if let chatStore {
                        ChatContent(store: store, config: config, chatStore: chatStore)
                    } else {
                        ProgressView("创建远程会话…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            if chatStore == nil, let client = store.client {
                let chat = ChatStore(client: client, profileID: config.profileID,
                                     sessionStore: sessionStore)
                // 断线重连成功后重新加载会话
                store.onReconnected = { Task { await chat.prepareSession() } }
                chatStore = chat
            }
        }
        .sheet(isPresented: $showSessions) {
            if let chatStore {
                SessionListView(
                    sessionStore: sessionStore,
                    profileID: config.profileID,
                    currentChatID: chatStore.chatID,
                    onSelect: { meta in
                        showSessions = false
                        Task { await chatStore.switchTo(chatID: meta.chatID) }
                    },
                    onNew: {
                        showSessions = false
                        Task { await chatStore.startNewSession() }
                    },
                    onDelete: { meta in
                        Task { await chatStore.deleteSession(chatID: meta.chatID) }
                    },
                    onRename: { meta, title in
                        chatStore.renameSession(chatID: meta.chatID, to: title)
                    }
                )
                .task { await chatStore.syncRemoteSessions() }
            }
        }
    }

    /// 自定义头部:[←返回] [链接名称(居中)] [🕐会话] [✕断开];返回 = 断开并回首页。图标按钮,仅辅助标签带文字。
    private var headerBar: some View {
        ZStack {
            HStack(spacing: 20) {
                Button {
                    store.disconnect()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                }
                .accessibilityLabel("返回")
                Spacer()
                Button {
                    showSessions = true
                } label: {
                    Image(systemName: "clock")
                        .font(.body)
                }
                .accessibilityLabel("历史会话")
                Button {
                    store.disconnect()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.body)
                }
                .accessibilityLabel("断开链接")
            }
            // 居中的链接名称(不拦截按钮点击)
            Text(config.name)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct ChatContent: View {
    @Bindable var store: ConnectionStore
    let config: ConnectionConfig
    let chatStore: ChatStore
    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            ConnectionStatusBar(state: store.state,
                                detail: chatStore.queueStatus ?? config.url)
            Divider()
            MessageList(chatStore: chatStore)
                .frame(maxWidth: .infinity)
            InputBar(
                text: $input,
                canSend: chatStore.isSessionReady &&
                    !chatStore.isReplayingHistory &&
                    !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                isResponding: chatStore.isResponding,
                onSend: {
                    let text = input
                    input = ""
                    Task { await chatStore.send(text) }
                },
                onStop: { Task { await chatStore.stop() } }
            )
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .top) {
            if let error = chatStore.errorMessage {
                HStack(spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button {
                        chatStore.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                }
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(8)
                .background(.bar, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)
                .padding(.top, 40)
                .transition(.opacity)
            }
        }
    }
}

/// 消息列表:自动滚动到最新;流式期间保持钉在底部。
private struct MessageList: View {
    let chatStore: ChatStore

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if chatStore.messages.isEmpty {
                        ContentUnavailableView(
                            "已连接 \(chatStore.chatID.map { "· \($0.prefix(8))" } ?? "")",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("输入消息开始远程对话")
                        )
                        .padding(.top, 80)
                    }
                    ForEach(chatStore.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .onChange(of: chatStore.messages.count) { _, _ in
                scrollToLast(proxy)
            }
            .onChange(of: chatStore.messages.last?.text) { _, _ in
                if chatStore.messages.last?.isStreaming == true {
                    scrollToLast(proxy)
                }
            }
            .overlay(alignment: .top) {
                if chatStore.isReplayingHistory {
                    Label("正在加载历史…", systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(.bar, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 8)
                }
            }
        }
    }

    private func scrollToLast(_ proxy: ScrollViewProxy) {
        guard let last = chatStore.messages.last else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}
