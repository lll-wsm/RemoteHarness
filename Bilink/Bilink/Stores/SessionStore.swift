import Foundation
import Observation

/// 历史会话目录:跨进程持久化所有会话的元数据(index.json),
/// 提供按连接地址过滤、最近会话优先,以及删除(同时清理本地消息文件)。
@Observable
final class SessionStore {
    private(set) var sessions: [SessionMeta] = []

    init() {
        load()
    }

    /// 会话目录文件(与消息记录同目录)。
    var indexURL: URL {
        dir.appendingPathComponent("index.json")
    }

    var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BilinkSessions", isDirectory: true)
    }

    // MARK: - 查询

    /// 指定连接地址的会话,按最近更新倒序。
    func sessions(for url: String) -> [SessionMeta] {
        sessions.filter { $0.connectionURL == url }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 该连接地址最近使用的会话,用于 App 重开/重连时自动恢复。
    func latest(for url: String) -> String? {
        sessions(for: url).first?.chatID
    }

    // MARK: - 更新

    /// 会话消息变化时刷新元数据;首次出现时创建条目。
    /// 标题取首个用户消息,建立后保持不变。
    func touch(chatID: String, connectionURL: String, messages: [ChatMessage], now: Date = Date()) {
        let preview = messages.last.map {
            $0.role == .user ? "👤 \($0.text)" : "🤖 \($0.text)"
        }
        if let index = sessions.firstIndex(where: { $0.chatID == chatID }) {
            var meta = sessions[index]
            // 空消息预建的条目(标题"新会话")在首条用户消息到达时补全标题
            if meta.title == "新会话", let first = messages.first(where: { $0.role == .user }) {
                meta.title = truncate(first.text)
            }
            meta.updatedAt = now
            meta.preview = preview
            meta.messageCount = messages.count
            sessions[index] = meta
        } else {
            let title: String
            if let first = messages.first(where: { $0.role == .user }) {
                title = truncate(first.text)
            } else {
                title = "新会话"
            }
            sessions.append(SessionMeta(chatID: chatID, title: title, preview: preview,
                                        messageCount: messages.count, createdAt: now,
                                        updatedAt: now, connectionURL: connectionURL))
        }
        save()
    }

    /// 删除会话:移除目录条目与本地消息文件。
    func delete(chatID: String) {
        sessions.removeAll { $0.chatID == chatID }
        let file = dir.appendingPathComponent("\(chatID).json")
        try? FileManager.default.removeItem(at: file)
        save()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        sessions = (try? JSONDecoder().decode([SessionMeta].self, from: data)) ?? []
    }

    private func save() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: indexURL)
    }

    private func truncate(_ text: String) -> String {
        text.count > 24 ? String(text.prefix(24)) + "…" : text
    }
}