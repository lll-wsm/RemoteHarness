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
            if case .reconnecting = store.state {
                HStack(spacing: 6) {
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                    Text("网络中断，正在重新连接…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
                Divider()
            } else if let queue = chatStore.queueStatus {
                HStack(spacing: 6) {
                    Circle().fill(Color.orange).frame(width: 8, height: 8)
                    Text(queue)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)
                Divider()
            }
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

/// 消息列表:智能滚动;流式期间钉底跟随，用户上滑回看时停住并提示回到最新。
private struct MessageList: View {
    let chatStore: ChatStore
    @State private var isPinned = true
    @State private var hasNewBelow = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if chatStore.messages.isEmpty {
                        ContentUnavailableView(
                            "远程对话",
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
            .onScrollGeometryChange(for: Bool.self) { geo in
                // 距底 = 内容高 - (偏移 + 视口高);≤120pt 视为钉底
                let distanceToBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                return distanceToBottom <= 120
            } action: { _, isNearBottom in
                isPinned = isNearBottom
                if isNearBottom {
                    hasNewBelow = false // 手动或自动滑回底部时清除提示
                }
            }
            .onChange(of: chatStore.messages.count) { _, _ in
                if isPinned {
                    scrollToLast(proxy, animated: true)
                }
            }
            .onChange(of: chatStore.messages.last?.text) { _, _ in
                guard chatStore.messages.last?.isStreaming == true else { return }
                if isPinned {
                    scrollToLast(proxy, animated: false) // 钉底高频 chunk 直接无动画滚动，防抖抗掉帧
                } else if !chatStore.isReplayingHistory {
                    hasNewBelow = true // 离底期间有新内容到达
                }
            }
            .onChange(of: chatStore.messages.last?.isStreaming) { _, streaming in
                // 流式结束:纯文本 -> Markdown 渲染,高度突变;count/text 均不变,需在此补偿。
                // async 到下一 runloop,滚到的才是渲染切换后的新高度。
                if streaming == false, isPinned {
                    DispatchQueue.main.async {
                        scrollToLast(proxy, animated: false)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if hasNewBelow {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            scrollToLast(proxy, animated: true)
                            hasNewBelow = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down")
                            Text("回到最新")
                        }
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    }
                    .overlay(alignment: .topTrailing) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .offset(x: 2, y: -2)
                    }
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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

    private func scrollToLast(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = chatStore.messages.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}
