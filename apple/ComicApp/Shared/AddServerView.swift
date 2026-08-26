import SwiftUI
import KomgaAPI
import KomgaStore

/// Add/edit server form enforcing the acceptance chain:
/// 添加服务器 → 登录（测试连接）→ 验证 Komga → 获取服务器信息 → 保存 Server Profile.
///
/// Save stays disabled until a connection test succeeds; the caller
/// (`LibraryViewModel`) persists secret → Keychain and profile → SQLite.
struct AddServerView: View {
    let model: LibraryViewModel
    let existing: ServerProfile?

    @Environment(\.dismiss) private var dismiss

    @State private var displayName = "Home"
    @State private var baseURL = ""
    @State private var authType: AuthType = .apiKey
    @State private var apiKey = ""
    @State private var username = ""
    @State private var password = ""

    @State private var phase: Phase = .idle
    @State private var saving = false

    private enum Phase {
        case idle
        case testing
        case tested(ConnectionResult)
        case error(String)
    }

    private var isEdit: Bool { existing != nil }

    private var secret: String {
        switch authType {
        case .apiKey: return apiKey
        case .basic: return "\(username)\n\(password)"
        }
    }

    private var canTest: Bool {
        let urlOK = !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
        switch authType {
        case .apiKey: return urlOK && !apiKey.isEmpty
        case .basic: return urlOK && !username.isEmpty && !password.isEmpty
        }
    }

    private var canSave: Bool {
        if case .tested = phase { return !saving && !displayName.trimmingCharacters(in: .whitespaces).isEmpty }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("显示名称", text: $displayName)
                    TextField("服务器地址", text: $baseURL)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        #endif
                    Picker("认证方式", selection: $authType) {
                        ForEach(AuthType.allCases) { type in
                            Text(type.label).tag(type)
                        }
                    }
                }
                Section("Authentication") {
                    switch authType {
                    case .apiKey:
                        SecureField("API Key（X-API-Key）", text: $apiKey)
                    case .basic:
                        TextField("用户名", text: $username)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                        SecureField("密码", text: $password)
                    }
                }
                Section {
                    Button {
                        Task { await runTest() }
                    } label: {
                        HStack {
                            if case .testing = phase {
                                ProgressView()
                            } else {
                                Text("测试连接")
                            }
                            Spacer()
                        }
                    }
                    .disabled(canTest == false || isTesting)

                    if case .tested(let result) = phase {
                        Label(
                            "Komga \(result.serverVersion ?? "版本未知") · \(result.libraries.count) 个库",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    }
                    if case .error(let message) = phase {
                        Label("连接失败：\(message)", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    if isEdit, case .idle = phase {
                        Text("编辑后需重新测试连接才能保存")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("保存") {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                }
            }
            .navigationTitle(isEdit ? "编辑服务器" : "添加服务器")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                if let existing {
                    displayName = existing.displayName
                    baseURL = existing.baseURL
                    authType = existing.authType
                }
            }
        }
    }

    private var isTesting: Bool {
        if case .testing = phase { return true }
        return false
    }

    private func runTest() async {
        phase = .testing
        do {
            let result = try await model.testConnection(baseURL: baseURL, authType: authType, secret: secret)
            phase = .tested(result)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    private func save() async {
        guard case .tested(let result) = phase else { return }
        saving = true
        defer { saving = false }
        if let existing {
            await model.updateServer(
                existing,
                displayName: displayName,
                baseURL: baseURL,
                authType: authType,
                secret: secret,
                result: result
            )
        } else {
            await model.addServer(
                displayName: displayName,
                baseURL: baseURL,
                authType: authType,
                secret: secret,
                result: result
            )
        }
        dismiss()
    }
}