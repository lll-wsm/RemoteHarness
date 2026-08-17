import Foundation
import Observation

/// 历史会话目录:跨进程持久化所有会话的元数据(index.json),按 profileID 归属;
/// 支持重命名、级联删除(profile/会话)与桥上远端合并(跨 profile 按 chatID 去重)。
/// 消息记录持久化在 BilinkSessions/<chatID>.json(按 chatID 扁平,同桥多 profile 共享)。
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

    /// 指定 profile 的会话,按最近更新倒序。
    func sessions(for profileID: UUID) -> [SessionMeta] {
        sessions.filter { $0.profileID == profileID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 该 profile 最近使用过的本地会话(排除桥上发现条目,用于自动恢复)。
    func latest(for profileID: UUID) -> String? {
        sessions(for: profileID).first { !$0.isRemoteOnly }?.chatID
    }

    /// 桥上发现的最新条目(仅 isRemoteOnly),供 prepareSession 的远端恢复分支。
    func latestRemoteOnly(for profileID: UUID) -> String? {
        sessions(for: profileID).first { $0.isRemoteOnly }?.chatID
    }

    /// 桥上发现的全部条目(按更新倒序),用于逐条尝试恢复/清理死会话。
    func remoteOnlyIDs(for profileID: UUID) -> [String] {
        sessions(for: profileID).filter { $0.isRemoteOnly }.map(\.chatID)
    }

    func meta(chatID: String) -> SessionMeta? {
        sessions.first { $0.chatID == chatID }
    }

    // MARK: - 更新

    /// 会话消息变化时刷新元数据;首次出现时创建条目。
    /// 标题取首个用户消息;「新会话」/「远端会话」占位符在首条消息到达后补全。
    /// isRemoteOnly 在本地首条消息落盘后翻转为 false(移出「桥上发现」分段)。
    func touch(chatID: String, profileID: UUID, messages: [ChatMessage], now: Date = Date()) {
        let preview = messages.last.map {
            $0.role == .user ? "👤 \($0.text)" : "🤖 \($0.text)"
        }
        if let index = sessions.firstIndex(where: { $0.chatID == chatID }) {
            var meta = sessions[index]
            if let first = messages.first(where: { $0.role == .user }) {
                // 占位标题(新会话/远端会话/远端发现时的 cwd 末段)在首条消息后补全
                if meta.isRemoteOnly || meta.title == "新会话" || meta.title == "远端会话" {
                    meta.title = truncate(first.text)
                }
            }
            if meta.isRemoteOnly {
                // 打开过(回放窗口结束或首条消息落盘)即视为本地使用,移出「桥上发现」分段
                meta.isRemoteOnly = false
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
                                        updatedAt: now, profileID: profileID))
        }
        save()
    }

    /// 重命名会话(本地与桥上发现条目均可)。
    func rename(chatID: String, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = sessions.firstIndex(where: { $0.chatID == chatID }) else { return }
        sessions[index].title = truncate(trimmed)
        save()
    }

    /// 删除会话:移除目录条目与本地消息文件。
    func delete(chatID: String) {
        sessions.removeAll { $0.chatID == chatID }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(chatID).json"))
        save()
    }

    /// 删除 profile 时级联清除其全部会话条目与消息文件。
    func removeProfile(profileID: UUID) {
        let chatIDs = sessions.filter { $0.profileID == profileID }.map(\.chatID)
        sessions.removeAll { $0.profileID == profileID }
        for chatID in chatIDs {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(chatID).json"))
        }
        save()
    }

    /// 合并桥上发现的远端会话(sessions/list 结果):
    /// 跨 profile 按 chatID 去重(同桥双 profile 不产生双条目);本地没有的
    /// 创建 isRemoteOnly 条目,标题回退链:cwd 末段 > "远端会话"。
    func mergeRemote(records: [[String: AnyCodable]], profileID: UUID) {
        var changed = false
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for record in records {
            guard let chatID = record["chatID"]?.stringValue,
                  !sessions.contains(where: { $0.chatID == chatID }) else { continue }
            let title: String
            if let cwd = record["cwd"]?.stringValue,
               let last = cwd.split(separator: "/").last, !last.isEmpty {
                title = truncate(String(last))
            } else {
                title = "远端会话"
            }
            let createdAt = record["createdAt"]?.stringValue
                .flatMap { formatter.date(from: $0) } ?? Date()
            sessions.append(SessionMeta(chatID: chatID, title: title,
                                        preview: "桥上发现", messageCount: 0,
                                        createdAt: createdAt, updatedAt: createdAt,
                                        profileID: profileID, isRemoteOnly: true))
            changed = true
        }
        if changed {
            save()
        }
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
