import SwiftUI
import KomgaStore
import KomgaDiagnostics

struct SettingsView: View {
    @ObservedObject var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var settings: AppSettings = AppSettings()
    @State private var cacheSizeBytes: Int64 = 0
    @State private var showOutboxSheet = false
    @State private var cacheClearedNotice = false

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                syncSection
                storageSection
                appearanceSection
                diagnosticsSection
            }
            .navigationTitle("设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                settings = model.appSettings
                updateCacheSize()
            }
            .sheet(isPresented: $showOutboxSheet) {
                OutboxSheet(model: model)
            }
        }
    }

    private var serverSection: some View {
        Section("当前服务器") {
            NavigationLink {
                ServersView(model: model)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.server?.displayName ?? "未连接服务器")
                            .font(.headline)
                        Text(model.server?.baseURL ?? "点击配置或切换服务器")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    private var syncSection: some View {
        Section("同步与网络") {
            Toggle("自动同步元数据", isOn: Binding(
                get: { settings.autoSyncMetadata },
                set: { val in
                    settings.autoSyncMetadata = val
                    model.updateAppSettings(settings)
                }
            ))

            Button {
                showOutboxSheet = true
            } label: {
                HStack {
                    Text("离线写操作队列")
                        .foregroundStyle(.primary)
                    Spacer()
                    if model.outboxPending > 0 {
                        Text("\(model.outboxPending) 项待同步")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            NavigationLink {
                DownloadsView(model: model)
            } label: {
                HStack {
                    Text("离线下载管理")
                    Spacer()
                    if !model.downloads.isEmpty {
                        Text("\(model.downloads.count) 本书")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                Task {
                    await model.reconcile(trigger: .manualRefresh)
                }
            } label: {
                HStack {
                    Text("立即手动同步")
                    Spacer()
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(model.isRefreshing || model.server == nil)
        }
    }

    private var storageSection: some View {
        Section(
            header: Text("存储与缓存"),
            footer: Text("清理缓存仅清除临时页面与封面，已下载的书籍和离线文件绝不会被删除。")
        ) {
            Picker("缓存上限", selection: Binding(
                get: { settings.cacheLimitMiB },
                set: { val in
                    settings.cacheLimitMiB = val
                    model.updateAppSettings(settings)
                }
            )) {
                Text("256 MiB").tag(256)
                Text("512 MiB").tag(512)
                Text("1024 MiB (1 GiB)").tag(1024)
            }

            HStack {
                Text("当前缓存占用")
                Spacer()
                Text(formatBytes(cacheSizeBytes))
                    .foregroundStyle(.secondary)
            }

            Button("清理页面缓存", role: .destructive) {
                model.clearDiskCache()
                updateCacheSize()
                cacheClearedNotice = true
            }
        }
    }

    private var appearanceSection: some View {
        Section("外观与布局") {
            Picker("深浅模式", selection: Binding(
                get: { settings.appearance },
                set: { val in
                    settings.appearance = val
                    model.updateAppSettings(settings)
                }
            )) {
                Text("跟随系统").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }

            Picker("书架网格密度", selection: Binding(
                get: { settings.gridDensity },
                set: { val in
                    settings.gridDensity = val
                    model.updateAppSettings(settings)
                }
            )) {
                Text("紧凑").tag("compact")
                Text("舒适").tag("comfortable")
                Text("宽松").tag("spacious")
            }
        }
    }

    private var diagnosticsSection: some View {
        Section("系统支持与关于") {
            NavigationLink {
                DiagnosticsView(model: model)
            } label: {
                Label("系统诊断与日志", systemImage: "stethoscope")
            }

            HStack {
                Text("客户端版本")
                Spacer()
                Text("1.0.0 (Release)")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func updateCacheSize() {
        cacheSizeBytes = model.diskCacheSizeBytes()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
