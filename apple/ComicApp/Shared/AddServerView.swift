import SwiftUI

/// Minimal Phase 0 server-config form: display name, base URL, API key.
/// On save the caller validates connectivity + auth against the real server.
struct AddServerView: View {
    let onSave: (String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var displayName = "Home"
    @State private var baseURL = ""
    @State private var apiKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Display Name", text: $displayName)
                    TextField("Server URL", text: $baseURL)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .autocorrectionDisabled()
                }
                Section("Authentication") {
                    SecureField("API Key", text: $apiKey)
                }
                Text("示例：http://192.168.1.10:25600")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("添加服务器")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        onSave(displayName, baseURL, apiKey)
                    }
                    .disabled(baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                #else
                ToolbarItem {
                    Button("取消") { dismiss() }
                }
                ToolbarItem {
                    Button("保存") {
                        onSave(displayName, baseURL, apiKey)
                    }
                    .disabled(baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                #endif
            }
        }
    }
}
