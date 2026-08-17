import Foundation
import Observation

/// 聊天状态:会话创建/恢复(session/new、session/load 或桥上远端发现)、
/// 发送(session/prompt)、流式事件组装(session/update → 消息追加)、
/// 停止(session/cancel)、删除/重命名/远端同步。
/// 会话目录与消息记录由 SessionStore 持久化;App 重开/重连按 profileID 三级恢复:
/// 本地最近会话 → 桥上发现的远端会话 → 新建。
@Observable
final class ChatStore {
    private(set) var messages: [ChatMessage] = []
    private(set) var isResponding = false
    private(set) var queueStatus: String?
    private(set) var chatID: String?
    private(set) var isSessionReady = false
    /// session/load 后的历史回放窗口期(回放事件无 isReplay 标记,按 load 后突发到达识别)。
    private(set) var isReplayingHistory = false
    var errorMessage: String?

    private let client: ACPClient
    private let profileID: UUID
    private let sessionStore: SessionStore
    private var isPreparing = false
    private var replayEndTask: Task<Void, Never>?

    init(client: ACPClient, profileID: UUID, sessionStore: SessionStore) {
        self.client = client
        self.profileID = profileID
        self.sessionStore = sessionStore
        client.onNotification = { [weak self] notification in
            self?.handle(notification)
        }
        Task { await self.prepareSession() }
    }

    // MARK: - 会话

    /// 建立或恢复远程会话(三级):本地最近会话 → 桥上发现的远端会话 → 新建。
    /// 初始化与重连后调用。
    func prepareSession() async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        errorMessage = nil
        if let stored = sessionStore.latest(for: profileID) {
            await resume(chatID: stored)
        } else if let remote = await syncRemoteSessions() {
            let ok = await resume(chatID: remote)
            if !ok {
                // 桥上发现但已失效(已移除死条目),直接新建
                await createSession()
            }
        } else {
            await createSession()
        }
    }

    /// 从历史列表切换到指定会话;切换前先取消旧会话的在途 turn。
    func switchTo(chatID stored: String) async {
        guard stored != chatID else { return }
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        // 在途 turn:先取消旧会话(桥的 cancel 按当前绑定注入,切走后将无法取消)
        if isResponding {
            _ = try? await client.send("session/cancel")
        }
        resetTurn()
        await resume(chatID: stored)
    }

    /// 新建会话(session/new),并持久化 chatID 与会话目录条目。
    func startNewSession() async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        await createSession()
    }

    /// 实际建会话:无守卫,供 prepareSession(已持锁)与 startNewSession(外部入口)复用。
    private func createSession() async {
        resetTurn()
        errorMessage = nil
        do {
            let result = try await client.send("session/new", params: .acp([:]))
            if let object = result?.objectValue, let id = object["chatID"]?.stringValue {
                chatID = id
                sessionStore.touch(chatID: id, profileID: profileID, messages: [])
            }
            isSessionReady = true
        } catch {
            isSessionReady = false
            errorMessage = (error as? ACPError)?.errorDescription ?? String(describing: error)
        }
    }

    /// 恢复指定会话:本地历史优先,再 session/load 接回远程上下文。
    /// 返回是否成功;桥上发现条目失败视为死会话,移除并提示。
    @discardableResult
    private func resume(chatID stored: String) async -> Bool {
        chatID = stored
        // 本地历史优先(已实例化的 grok 会话不再回放,界面历史必须本地持久)
        messages = loadLocalHistory()
        let isRemoteOnly = sessionStore.meta(chatID: stored)?.isRemoteOnly == true
        do {
            _ = try await client.send("session/load", params: .acp(["chatID": stored]))
            isSessionReady = true
            // 本地无历史(远端发现/重装)时依赖 grok 回放
            if messages.isEmpty {
                startReplayWindow()
            }
            return true
        } catch {
            isSessionReady = false
            isReplayingHistory = false
            if isRemoteOnly {
                // 注册表有记录但 grok 侧已失效(如 serve 重启):移除死条目
                sessionStore.delete(chatID: stored)
                errorMessage = "远端会话已失效,已从列表移除"
            } else {
                errorMessage = "远程会话不可用,本地记录已保留,可新建会话"
            }
            return false
        }
    }

    /// 切换/新建前清理在途状态。
    private func resetTurn() {
        replayEndTask?.cancel()
        replayEndTask = nil
        isResponding = false
        isReplayingHistory = false
        queueStatus = nil
        messages = []
    }

    /// 历史回放窗口:load 后 grok 会突发回放历史事件,2 秒后结束。
    private func startReplayWindow() {
        isReplayingHistory = true
        replayEndTask?.cancel()
        replayEndTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.isReplayingHistory = false }
        }
    }

    // MARK: - 会话管理入口

    /// 远端同步:桥 sessions/list → 合并进目录;返回最新的桥上发现条目(供 prepare 恢复)。
    @discardableResult
    func syncRemoteSessions() async -> String? {
        do {
            let result = try await client.send("sessions/list", params: .acp([:]))
            guard let sessions = result?.objectValue?["sessions"]?.arrayValue else { return nil }
            sessionStore.mergeRemote(records: sessions.compactMap { $0.objectValue },
                                     profileID: profileID)
            return sessionStore.latestRemoteOnly(for: profileID)
        } catch {
            return nil
        }
    }

    /// 删除会话:需在线(桥 sessions/remove → 本地清理);目标是当前会话时随后新建。
    /// 断线时保留本地并提示,不做"仅删本地"。
    func deleteSession(chatID target: String) async {
        do {
            _ = try await client.send("sessions/remove", params: .acp(["chatID": target]))
            sessionStore.delete(chatID: target)
            if target == chatID {
                await startNewSession()
            }
        } catch {
            errorMessage = "删除失败:需在线删除(本地记录已保留)"
        }
    }

    /// 重命名会话(本地与桥上发现条目均可)。
    func renameSession(chatID target: String, to newTitle: String) {
        sessionStore.rename(chatID: target, to: newTitle)
    }

    // MARK: - 本地历史持久化

    private var historyFileURL: URL? {
        guard let chatID else { return nil }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BilinkSessions", isDirectory: true)
        return dir.appendingPathComponent("\(chatID).json")
    }

    private func loadLocalHistory() -> [ChatMessage] {
        guard let url = historyFileURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ChatMessage].self, from: data)) ?? []
    }

    private func saveLocalHistory() {
        guard let url = historyFileURL, !messages.isEmpty else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: url)
    }

    // MARK: - 发送 / 停止

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        messages.append(ChatMessage(role: .user, text: trimmed))
        saveLocalHistory()
        touchSessionMeta()
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

    /// 消息变化后同步会话目录(标题/摘要/时间;远端条目首条消息后翻转)。
    private func touchSessionMeta() {
        guard let chatID else { return }
        sessionStore.touch(chatID: chatID, profileID: profileID, messages: messages)
    }

    // MARK: - 事件处理

    private func handle(_ notification: RPCNotification) {
        // 通知来自 URLSession 后台队列,跳回主线程更新 UI 状态
        Task { @MainActor in
            self.handleOnMain(notification)
        }
    }

    private func handleOnMain(_ notification: RPCNotification) {
        // 多会话并存时,桥在转发通知时注入 chatID;只处理当前会话的事件
        if let params = notification.params?.objectValue,
           let noteChatID = params["chatID"]?.stringValue, noteChatID != chatID {
            return
        }
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
            // 回放时回显用户历史;实时回显忽略(已本地追加)
            if isReplayingHistory,
               let text = update["content"]?.objectValue?["text"]?.stringValue, !text.isEmpty {
                messages.append(ChatMessage(role: .user, text: text))
            }
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
        case "retry_state":
            // grok 经 _x.ai/session_notification 上报的会话级错误(如 API 额度耗尽)
            if update["type"]?.stringValue == "failed" {
                finalizeTurn()
                errorMessage = errorText(errorType: update["error_type"]?.stringValue,
                                        message: update["message"]?.stringValue)
            }
        default:
            break
        }
    }

    /// 将 grok 上报的错误类型翻译为可读信息。
    private func errorText(errorType: String?, message: String?) -> String {
        switch errorType {
        case "quota_exhausted":
            return "API 额度不足,请检查模型账户余额"
        case "rate_limit":
            return "请求过于频繁,请稍后重试"
        default:
            return message ?? "模型调用失败,请稍后重试"
        }
    }

    private func appendToStreamingAssistant(text: String, thought: String) {
        if let index = messages.indices.last,
           messages[index].role == .assistant, messages[index].isStreaming {
            messages[index].text += text
            messages[index].thought += thought
        } else {
            // 历史回放的消息是完整内容,不进入流式状态
            messages.append(ChatMessage(role: .assistant, text: text,
                                        thought: thought, isStreaming: !isReplayingHistory))
        }
    }

    private func finalizeTurn() {
        if let index = messages.indices.last, messages[index].role == .assistant {
            messages[index].isStreaming = false
        }
        isResponding = false
        queueStatus = nil
        saveLocalHistory()
        touchSessionMeta()
    }
}