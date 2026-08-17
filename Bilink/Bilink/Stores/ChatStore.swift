import Foundation
import Observation

/// 聊天状态:会话创建(session/new)、发送(session/prompt)、
/// 流式事件组装(session/update → 消息追加)、停止(session/cancel)。
@Observable
final class ChatStore {
    private(set) var messages: [ChatMessage] = []
    private(set) var isResponding = false
    private(set) var queueStatus: String?
    private(set) var chatID: String?
    private(set) var isSessionReady = false
    private(set) var errorMessage: String?

    private let client: ACPClient
    private var didStartSession = false

    init(client: ACPClient) {
        self.client = client
        client.onNotification = { [weak self] notification in
            self?.handle(notification)
        }
        Task { await self.createSessionIfNeeded() }
    }

    // MARK: - 会话

    /// 首次进入时创建远程 grok 会话;chatID 由桥返回(M2.3 做持久化恢复)。
    func createSessionIfNeeded() async {
        guard !didStartSession else { return }
        didStartSession = true
        do {
            let result = try await client.send("session/new", params: .acp([:]))
            if let object = result?.objectValue, let id = object["chatID"]?.stringValue {
                chatID = id
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
