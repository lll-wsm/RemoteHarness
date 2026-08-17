import SwiftUI

/// 新增/编辑机器表单;token 只写不读(编辑已有机器时留空表示不改)。
struct ProfileEditView: View {
    let profileStore: ProfileStore
    let profile: ConnectionProfile?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""

    private var isNew: Bool { profile == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("机器") {
                    TextField("名称(如:办公室 Mac)", text: $name)
                    TextField("地址(ws:// 或 wss://)", text: $url)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section("Token") {
                    SecureField(isNew ? "桥的 BRIDGE_TOKEN" : "桥的 BRIDGE_TOKEN(留空不改)", text: $token)
                }
            }
            .navigationTitle(isNew ? "添加机器" : "编辑机器")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .onAppear {
            if let profile {
                name = profile.name
                url = profile.url
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !url.trimmingCharacters(in: .whitespaces).isEmpty &&
        (isNew ? !token.isEmpty : true)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        if let profile {
            var updated = profile
            updated.name = trimmedName
            updated.url = trimmedURL
            profileStore.update(updated, token: token.isEmpty ? nil : token)
        } else {
            profileStore.add(name: trimmedName, url: trimmedURL, token: token)
        }
        dismiss()
    }
}
