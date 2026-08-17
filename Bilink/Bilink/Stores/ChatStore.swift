import Foundation
import Observation

/// 聊天状态:会话创建/恢复(session/new 或 session/load)、发送(session/prompt)、
/// 流式事件组装(session/update → 消息追加)、停止(session/cancel)。
/// chatID 持久化到 UserDefaults(按连接 URL 分键),重进/重连后 session/load 恢复。
@Observable
final class ChatStore {
    private(set) var messages: [ChatMessage] = []
    private(set) var isResponding = false
    private(set) var queueStatus: String?
    private(set) var chatID: String?
    private(set) var isSessionReady = false
    var errorMessage: String?

    private let client: ACPClient
    private let connectionURL: String
    private var isPreparing = false

    init(client: ACPClient, connectionURL: String) {
        self.client = client
        self.connectionURL = connectionURL
        client.onNotification = { [weak self] notification in
            self?.handle(notification)
        }
        Task { await self.prepareSession() }
    }

    private var chatIDKey: String {
        "bilink.chatID.\(connectionURL)"
    }

    private var storedChatID: String? {
        get { UserDefaults.standard.string(forKey: chatIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: chatIDKey) }
    }

    // MARK: - 会话

    /// 建立或恢复远程会话:有已存 chatID → session/load 恢复;否则 session/new 新建并持久化。
    /// 重连后由 ConnectionStore.onReconnected 再次调用。
    func prepareSession() async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        errorMessage = nil

        if let stored = storedChatID {
            chatID = stored
            do {
                _ = try await client.send("session/load", params: .acp(["chatID": stored]))
                isSessionReady = true
                return
            } catch {
                // 加载失败(如桥重启丢了注册表),回退新建
                chatID = nil
            }
        }
        await createSession()
    }

    private func createSession() async {
        do {
            let result = try await client.send("session/new", params: .acp([:]))
            if let object = result?.objectValue, let id = object["chatID"]?.stringValue {
                chatID = id
                storedChatID = id
            }
            isSessionReady = true
        } catch {
            errorMessage = (error as? ACPError)?.errorDescription ?? String(describing: error)
        }
    }

    // MARK: - 发送 / 停止

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        messages.append(ChatMessage(role: .user, text: trimmed))
        isResponding = true
        queueStatus = "发送中…"
        do {
            _ = try await client.send("session/prompt", params: .acp(["prompt": trimmed]))
            // 整轮结束的响应到达,流式通知已完成
            isResponding = false
        } catch {
            isResponding = false
            errorMessage = (error as? ACPError)?.errorDescription ?? String(describing: error)
        }
    }

    func stop() async {
        _ = try? await client.send("session/cancel")
    }

    // MARK: - 事件处理

    private func handle(_ notification: RPCNotification) {
        // 通知来自 URLSession 后台队列,跳回主线程更新 UI 状态
        Task { @MainActor in
            self.handleOnMain(notification)
        }
    }

    private func handleOnMain(_ notification: RPCNotification) {
        if notification.method == "_x.ai/queue/changed",
           let params = notification.params?.objectValue {
            let hasQueue = (params["entries"]?.arrayValue?.isEmpty == false) ||
                (params["runningPromptId"]?.stringValue != nil)
            queueStatus = hasQueue ? "排队中…" : nil
            return
        }
        guard let params = notification.params?.objectValue,
              let update = params["update"]?.objectValue,
              let kind = update["sessionUpdate"]?.stringValue else { return }
        switch kind {
        case "user_message_chunk":
            break // 用户消息已本地追加,忽略回显
        case "agent_thought_chunk":
            if let text = update["content"]?.objectValue?["text"]?.stringValue, !text.isEmpty {
                appendToStreamingAssistant(text: "", thought: text)
            }
        case "agent_message_chunk":
            if let text = update["content"]?.objectValue?["text"]?.stringValue, !text.isEmpty {
                appendToStreamingAssistant(text: text, thought: "")
            }
        case "response_completed", "turn_completed":
            finalizeTurn()
        default:
            break
        }
    }

    private func appendToStreamingAssistant(text: String, thought: String) {
        if let index = messages.indices.last,
           messages[index].role == .assistant, messages[index].isStreaming {
            messages[index].text += text
            messages[index].thought += thought
        } else {
            messages.append(ChatMessage(role: .assistant, text: text,
                                        thought: thought, isStreaming: true))
        }
    }

    private func finalizeTurn() {
        if let index = messages.indices.last, messages[index].role == .assistant {
            messages[index].isStreaming = false
        }
        isResponding = false
        queueStatus = nil
    }
}
