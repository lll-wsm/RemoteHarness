import Foundation
import Observation

/// 多连接档案:profiles.json 持久化机器列表,token 只存 Keychain
/// (键 `bilink.token.profile.<id>`,随 profile 而非 URL)。
@Observable
final class ProfileStore {
    private(set) var profiles: [ConnectionProfile] = []

    init() {
        load()
    }

    var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BilinkProfiles/profiles.json", isDirectory: false)
    }

    // MARK: - 查询

    func token(for id: UUID) -> String? {
        KeychainService.read(key(for: id))
    }

    // MARK: - 增删改

    @discardableResult
    func add(name: String, url: String, token: String) -> ConnectionProfile {
        let profile = ConnectionProfile(id: UUID(), name: name, url: url,
                                        createdAt: Date(), lastUsedAt: Date())
        KeychainService.save(token, forKey: key(for: profile.id))
        profiles.append(profile)
        sortByLastUsed()
        save()
        return profile
    }

    /// 更新 name/url;token 非 nil 时同时更新 Keychain(token 编辑时留空表示不改)。
    func update(_ profile: ConnectionProfile, token: String?) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        if let token {
            KeychainService.save(token, forKey: key(for: profile.id))
        }
        save()
    }

    /// 连接成功后刷新 lastUsedAt 并重排。
    func touch(_ profile: ConnectionProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].lastUsedAt = Date()
        sortByLastUsed()
        save()
    }

    /// 删除机器:级联 Keychain token;本地会话由调用方一并清理(SessionStore.removeProfile)。
    func delete(id: UUID) {
        profiles.removeAll { $0.id == id }
        KeychainService.delete(key(for: id))
        save()
    }

    // MARK: - 持久化

    private func key(for id: UUID) -> String {
        "bilink.token.profile.\(id.uuidString)"
    }

    private func sortByLastUsed() {
        profiles.sort { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        profiles = (try? JSONDecoder().decode([ConnectionProfile].self, from: data)) ?? []
        sortByLastUsed()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: fileURL)
    }
}