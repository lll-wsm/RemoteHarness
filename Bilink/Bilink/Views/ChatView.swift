import SwiftUI

/// 聊天页:M2.2 完整实现——消息列表(流式)+ 输入栏 + 状态条。
struct ChatView: View {
    @Bindable var store: ConnectionStore
    let config: ConnectionConfig
    @State private var chatStore: ChatStore?

    var body: some View {
        Group {
            if let chatStore {
                ChatContent(store: store, config: config, chatStore: chatStore)
            } else {
                ProgressView("创建远程会话…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if chatStore == nil, let client = store.client {
                let chat = ChatStore(client: client, connectionURL: config.url)
                // 断线重连成功后重新加载会话
                store.onReconnected = { Task { await chat.prepareSession() } }
                chatStore = chat
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("断开") { store.disconnect() }
            }
        }
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
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            InputBar(
                text: $input,
                canSend: chatStore.isSessionReady &&
                    !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                isResponding: chatStore.isResponding,
                onSend: {
                    let text = input
                    input = ""
                    Task { await chatStore.send(text) }
                },
                onStop: { Task { await chatStore.stop() } }
            )
            .frame(maxWidth: 720)
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
        }
    }

    private func scrollToLast(_ proxy: ScrollViewProxy) {
        guard let last = chatStore.messages.last else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}
